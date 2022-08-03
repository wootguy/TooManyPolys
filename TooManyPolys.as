#include "HashMap"
#include "UserInfo"
#include "GhostReplace"
#include "PlayerModelPrecache"
#include "util"

// TODO:
// - performance improvements?
// - angles dont work while dead
// - special characters in names mess up .listpoly table alignment
// - replace knuckles models with 2d
// - re-apply replacement when changing a userinfo setting
// - poly count wrong when ghost model not precached
// - constantly update ghost renders instead of adding special logic?
// - show if model is precached in .listpoly
// - ghost disappears in third person
// - precache and force latest model if someone is using an alias or older versions that isnt on the server
// - include hats in poly count calculation

// can't reproduce:
// - vis checks don't work sometimes:
//   - only on map start? Not until everyone connected with non-0 ping?
//   - only the spawn area? (hunger, rc_labyrinth)

void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

class ModelInfo {
	string officialName;
	uint32 polys = defaultLowpolyModelPolys;
	string replacement_sd = defaultLowpolyModel; // standard-def replacement, lower poly but still possibly too high
	string replacement_ld = defaultLowpolyModel; // lowest-def replacement, should be a 2D model or the default replacement
	
	bool hasSdModel() {
		return replacement_sd != replacement_ld && replacement_sd != defaultLowpolyModel;
	}
}

enum LEVEL_OF_DETAIL
{
	LOD_HD,
	LOD_SD,
	LOD_LD
}

class PlayerState {
	bool prefersHighPoly = true; // true if player would rather have horrible FPS than see low poly models
	int polyLimit = cvar_default_poly_limit.GetInt();
	string lastNagModel = ""; // name of the model that the player was last nagged about
	float lastJoinTime = 0;
	int lagState;
	float lastRefresh;
	bool finishedRefresh = false;
	bool wasLoaded = false;
	
	array<EHandle> refreshList; // player models to refresh, once they come into view
	
	bool modelSwapAll = false;
	string modelSwapAllModel = "";
	dictionary modelSwaps;
	dictionary modelUnswaps;
	
	string getSwapModel(CBasePlayer@ target) {
		if (modelSwapAll) {
			return modelSwapAllModel;
		}
	
		string steamid = g_EngineFuncs.GetPlayerAuthId(target.edict()).ToLowercase();
			
		if (modelSwaps.exists(steamid)) {
			string swap;
			modelSwaps.get(steamid, swap);
			return swap;
		}
		
		return "";
	}
}

string g_model_list_path = "scripts/plugins/TooManyPolys/models.txt";
string g_alias_list_path = "scripts/plugins/TooManyPolys/aliases.txt";
const int hashmapBucketCount = 4096;
HashMapModelInfo g_model_list(hashmapBucketCount);
CCVar@ cvar_default_poly_limit;
dictionary g_player_states;

const string defaultLowpolyModel = "player-10up";
const string refreshModel = "ark"; // model swapped to when refreshing player models (should be small for fast loading)
const string defaultLowpolyModelPath = "models/player/" + defaultLowpolyModel + "/" + defaultLowpolyModel + ".mdl";
const string refreshModelPath = "models/player/" + refreshModel + "/" + refreshModel + ".mdl";
const int defaultLowpolyModelPolys = 142;
const int unknownModelPolys = 50000; // assume the worst (better not to risk lowering FPS)

const string moreInfoMessage = "Type '.hipoly' in console for more info.";

array<string> g_cachedUserInfo(33); // used to detect when user info has changed, which undos model replacement
array<GhostReplace> g_ghostCopys;
array<string> g_precachedModels;
array<bool> g_wasObserver(33);

bool g_paused = false; // debug performance issues

class Replacement {
	EHandle h_ent; // entity being replaced
	EHandle h_owner; // player which owns the entity (to know which model is used)
	int lod = LOD_HD; // current level of detail
	string model;
}

void PluginInit() {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "asdf" );
	
	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @ClientSay );
	g_Hooks.RegisterHook( Hooks::Player::ClientPutInServer, @ClientJoin );
	g_Hooks.RegisterHook( Hooks::Player::ClientDisconnect, @ClientLeave );
	g_Hooks.RegisterHook( Hooks::Player::PlayerEnteredObserver, @PlayerEnteredObserver );
	g_Hooks.RegisterHook( Hooks::Game::MapChange, @MapChange );
	
	@cvar_default_poly_limit = CCVar("default_poly_limit", 32000, "max player visble polys", ConCommandFlag::AdminOnly);
	
	load_model_list();
	
	g_Scheduler.SetInterval("check_if_swaps_needed", 0.5, -1);
	g_Scheduler.SetInterval("check_model_names", 1.0, -1);
	g_Scheduler.SetInterval("update_ghost_models", 0.05, -1);
	g_Scheduler.SetInterval("loadCrossPluginAfkState", 1.0f, -1);
	g_Scheduler.SetInterval("fix_new_model_dl_bug", 0.2f, -1);
	
	loadPrecachedModels();
}

void PluginExit() {
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		if (plr is null or !plr.IsConnected())
			continue;
		
		UserInfo(plr).broadcast();
	}
	
	for (uint i = 0; i < g_ghostCopys.size(); i++) {
		g_EntityFuncs.Remove(g_ghostCopys[i].ghostSD);
		g_EntityFuncs.Remove(g_ghostCopys[i].ghostLD);
		g_EntityFuncs.Remove(g_ghostCopys[i].ghostRenderSD);
		g_EntityFuncs.Remove(g_ghostCopys[i].ghostRenderLD);
	}
}

void MapInit() {
	precachePlayerModels();
	
	for (uint i = 0; i < 33; i++) {
		g_wasObserver[i] = false;
		g_cachedUserInfo[i] = "";
	}
	
	g_refresh_idx = 0;
}

// Will create a new state if the requested one does not exit
PlayerState@ getPlayerState(CBasePlayer@ plr) {
	if (plr is null or !plr.IsConnected())
		return null;
		
	string steamId = g_EngineFuncs.GetPlayerAuthId( plr.edict() );
	if (steamId == 'STEAM_ID_LAN' or steamId == 'BOT') {
		steamId = plr.pev.netname;
	}
	
	if ( !g_player_states.exists(steamId) )
	{
		PlayerState state;
		g_player_states[steamId] = state;
	}
	return cast<PlayerState@>( g_player_states[steamId] );
}

HookReturnCode ClientJoin( CBasePlayer@ plr ) {
	PlayerState@ pstate = getPlayerState(plr);
	pstate.lastJoinTime = g_Engine.time;
	pstate.lastRefresh = -999;
	pstate.refreshList.resize(0);
	
	g_Scheduler.SetTimeout("post_join", 0.5f, EHandle(plr));

	return HOOK_CONTINUE;
}

HookReturnCode PlayerEnteredObserver( CBasePlayer@ plr ) {
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "deadplayer"); 
		if (ent !is null) {
			CustomKeyvalues@ pCustom = ent.GetCustomKeyvalues();
			CustomKeyvalue ownerKey( pCustom.GetKeyvalue( "$i_hipoly_owner" ) );
			
			if (!ownerKey.Exists()) {
				pCustom.SetKeyvalue("$i_hipoly_owner", plr.entindex());
				println("Set owner for corpse! " + ent.pev.classname);
			}
		}
	} while (ent !is null);
	
	return HOOK_CONTINUE;
}

void loadCrossPluginAfkState() {
	CBaseEntity@ afkEnt = g_EntityFuncs.FindEntityByTargetname(null, "PlayerStatusPlugin");
	
	if (afkEnt is null) {
		return;
	}
	
	CustomKeyvalues@ customKeys = afkEnt.GetCustomKeyvalues();
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		PlayerState@ state = getPlayerState(plr);
		
		CustomKeyvalue key2 = customKeys.GetKeyvalue("$i_state" + i);

		if (key2.Exists()) {
			state.lagState = key2.GetInteger();
			
			if (state.lagState == 0 and !state.wasLoaded) {
				for ( int k = 1; k <= g_Engine.maxClients; k++ ) {
					CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(k);
					
					if (p is null or !p.IsConnected() or i == k) {
						continue;
					}
					
					state.refreshList.insertLast(p);
					state.finishedRefresh = false;
				}
				
				state.wasLoaded = true;
			}
		}
	}
}

// swap all models with something else and back again to fix newly downloaded models appearing as the helmet model
uint g_refresh_idx = 0;
float refreshDelay = 0.5f;
void fix_new_model_dl_bug() {	
	int totalChecks = 0;
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}		
		
		PlayerState@ state = getPlayerState(plr);
		if (state.lagState != 0) {
			continue;
		}
		
		// don't refresh too fast in case player lags when loading a huge player model
		if (g_Engine.time - state.lastRefresh < refreshDelay) {
			continue;
		}
		
		if (state.refreshList.size() == 0) {
			if (!state.finishedRefresh) {
				do_model_swaps(EHandle(plr));
			}
			state.finishedRefresh = true;
			continue;
		}
		
		// only do one check per player, per loop, to prevent lag
		uint idx = g_refresh_idx % state.refreshList.size();

		CBaseEntity@ target = state.refreshList[idx];
		
		if (target is null) {
			state.refreshList.removeAt(idx);
			continue;
		}
		
		if (target.pev.effects & EF_NODRAW != 0) {
			continue;
		}
	
		TraceResult tr;
		g_Utility.TraceLine(plr.pev.origin, target.pev.origin, ignore_monsters, plr.edict(), tr);
		
		if (tr.flFraction >= 1.0f) {
			//g_PlayerFuncs.ClientPrint(plr, HUD_PRINTNOTIFY, "Refreshing player model for " + target.pev.netname + "\n");
		
			refresh_player_model(EHandle(plr), EHandle(target), false);
			g_Scheduler.SetTimeout("refresh_player_model", 0.1f, EHandle(plr), EHandle(target), true);
			
			state.refreshList.removeAt(idx);
			state.lastRefresh = g_Engine.time;
		}
	}
	
	g_refresh_idx++;
}

void refresh_player_model(EHandle h_looker, EHandle h_target, bool isPostSwap) {
	CBasePlayer@ looker = cast<CBasePlayer@>(h_looker.GetEntity());
	CBasePlayer@ target = cast<CBasePlayer@>(h_target.GetEntity());
	
	if (looker is null or target is null) {
		return;
	}
	
	UserInfo userInfo = UserInfo(target);
	
	if (isPostSwap) {
		KeyValueBuffer@ pInfos = g_EngineFuncs.GetInfoKeyBuffer( target.edict() );
		string currentModel = pInfos.GetValue( "model" ).ToLowercase();
	
		userInfo.model = currentModel;
		userInfo.send(looker);
	} else {
		userInfo.model = refreshModel;
		userInfo.send(looker);
	}
}

void post_join(EHandle h_plr) {
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	
	if (plr is null) {
		return;
	}
	
	addPlayerModel(plr);

	for (uint i = 0; i < g_ghostCopys.size(); i++) {
		g_ghostCopys[i].setLod(plr, LOD_HD);
	}
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
		CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (p is null or !p.IsConnected()) {
			continue;
		}
		
		PlayerState@ state = getPlayerState(p);
		state.refreshList.insertLast(EHandle(plr));
		state.finishedRefresh = false;
	}
	
	do_model_swaps(EHandle(null));
}

HookReturnCode ClientLeave(CBasePlayer@ plr) {
	g_Scheduler.SetTimeout("do_model_swaps", 0.5f, EHandle(plr));
	return HOOK_CONTINUE;
}

HookReturnCode MapChange() {
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
		addPlayerModel(g_PlayerFuncs.FindPlayerByIndex(i));
	}

	return HOOK_CONTINUE;
}

void load_model_list() {
	g_model_list.clear(hashmapBucketCount);
	
	File@ f = g_FileSystem.OpenFile( g_model_list_path, OpenFile::READ );
	if (f is null or !f.IsOpen())
	{
		println("TooManyPolys: Failed to open " + g_model_list_path);
		return;
	}
	
	int modelCount = 0;
	string line;
	while( !f.EOFReached() )
	{
		f.ReadLine(line);
		
		if (line.Length() == 0) {
			continue;
		}
		
		array<string> parts = line.Split("/");
		string model_name = parts[0];
		int poly_count = atoi(parts[1]);
		string sd_model = parts[2];
		string ld_model = parts[3];
		//println("LOAD " + model_name + " " + poly_count + " " + replace_model);
		
		ModelInfo info;
		info.officialName = model_name.ToLowercase();
		info.polys = poly_count;
		info.replacement_sd = sd_model.Length() > 0 ? sd_model : defaultLowpolyModel;
		info.replacement_ld = ld_model.Length() > 0 ? ld_model : defaultLowpolyModel;
		
		g_model_list.put(model_name, info);
		modelCount++;
	}
	
	println("TooManyPolys: Loaded " + modelCount + " models from " + g_model_list_path);
	
	load_aliases();
}

// redirect old versions and aliases to the latest version of the model
void load_aliases() {	
	File@ f = g_FileSystem.OpenFile( g_alias_list_path, OpenFile::READ );
	if (f is null or !f.IsOpen())
	{
		println("TooManyPolys: Failed to open " + g_alias_list_path);
		return;
	}
	
	int aliasCount = 0;
	string line;
	while( !f.EOFReached() )
	{
		f.ReadLine(line);		
		
		if (line.Length() == 0) {
			continue;
		}
		
		array<string> parts = line.Split("/");

		string latest_model_name = parts[0];
		//println("TRY " + latest_model_name);
		
		if (!g_model_list.exists(latest_model_name)) {
			//println("TooManyPolys: Alias info references unknown model: " + line);
			continue;
		}
		
		ModelInfo latest_info = g_model_list.get(latest_model_name);
		
		for (uint i = 1; i < parts.size(); i++) {
			if (!g_model_list.exists(parts[i])) {
				g_model_list.put(parts[i], latest_info);
				aliasCount++;
			}
		}
	}
	
	println("TooManyPolys: Duplicated " + aliasCount + " ModelInfos from " + g_alias_list_path);
	
	//g_model_list.stats();
}

class PlayerModelInfo {
	CBaseEntity@ ent;
	CBasePlayer@ owner; // if plr is a dead body, then this is the owning player
	string desiredModel;
	int desiredPolys;
	int replacePolys;
	string steamid;
	bool canReplace;
	
	Replacement currentReplacement;
	
	PlayerModelInfo() {}
	
	CBaseEntity@ getOwner() {
		if (ent.pev.classname == "deadplayer" or ent.pev.classname == "cycler") {
			if (owner !is null) {
				return @owner;
			} else {
				return null;
			}
		} else {
			return @ent; // players own their "player" entity
		}
	}
	
	// this entity's model has an SD version
	bool canReplaceSd() {		
		if (g_model_list.exists(desiredModel)) {
			ModelInfo info = g_model_list.get(desiredModel);
			return info.hasSdModel();			
		}
		
		return false;
	}
	
	// returns the polys for the given LOD on the entity
	// the default low poly model is used if no known replacement exists
	int getReplacementPolys(bool standardDefNotLowDef) {
		int multiplier = ent.pev.renderfx == kRenderFxGlowShell ? 2 : 1;
		int replacePolys = defaultLowpolyModelPolys * multiplier;
		
		if (g_model_list.exists(desiredModel)) {
			ModelInfo info = g_model_list.get(desiredModel);
		
			string replace_model = standardDefNotLowDef ? info.replacement_sd : info.replacement_ld;
			ModelInfo replaceInfo = g_model_list.get(replace_model);
			
			replacePolys = replaceInfo.polys * multiplier;
			if (desiredPolys < replacePolys) {
				println("Replacement model is higher poly! (" + desiredModel + "(" + desiredPolys + ") -> " + replace_model + " (" + replacePolys + ")");
			}
		}
		
		return replacePolys;
	}
	
	bool hasOwner() {
		return getOwner() !is null;
	}
}

array<PlayerModelInfo> get_visible_players(int&out totalPolys, int&out totalPlayers) {		
	array<PlayerModelInfo> pvsPlayerInfos;
	
	totalPolys = 0;
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {		
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected() or plr.GetObserver().IsObserver())
			continue;
		
		PlayerModelInfo info;
		@info.ent = @plr;
		info.desiredModel = getDesiredModel(plr);
		info.desiredPolys = getModelPolyCount(plr, info.desiredModel);
		info.replacePolys = info.desiredPolys;
		info.currentReplacement.h_ent = EHandle(plr);
		info.currentReplacement.h_owner = EHandle(plr);
		info.steamid = g_EngineFuncs.GetPlayerAuthId(plr.edict()).ToLowercase();
		pvsPlayerInfos.insertLast(info);
		totalPolys += info.desiredPolys;
	}
	
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByTargetname(ent, "plugin_ghost_cam_*");
		
		if (ent is null or string(ent.pev.model) == "models/as_ghosts/camera.mdl") {
			continue;
		}
		
		CBasePlayer@ owner = g_PlayerFuncs.FindPlayerByIndex(ent.pev.iuser2);
		
		if (owner is null) {
			continue;
		}
	
		PlayerModelInfo info;
		@info.ent = @ent;
		info.desiredModel = getDesiredModel(owner);
		info.desiredPolys = getModelPolyCount(owner, info.desiredModel);
		info.replacePolys = info.desiredPolys;
		info.currentReplacement.h_ent = EHandle(ent);
		info.currentReplacement.h_owner = EHandle(owner);
		info.steamid = g_EngineFuncs.GetPlayerAuthId(owner.edict()).ToLowercase();
		pvsPlayerInfos.insertLast(info);
		totalPolys += info.desiredPolys;
	} while (ent !is null);
	
	totalPlayers = pvsPlayerInfos.size();
	
	return pvsPlayerInfos;
}

void reset_models(CBasePlayer@ forPlayer) {
	if (forPlayer !is null) {
		for ( int i = 1; i <= g_Engine.maxClients; i++ )
		{
			CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
			if (plr is null or !plr.IsConnected())
				continue;
			
			UserInfo(plr).send(forPlayer);
		}
	
		for (uint i = 0; i < g_ghostCopys.size(); i++) {
			g_ghostCopys[i].setLod(forPlayer, LOD_HD);
		}
	}
}

string getLodModel(CBasePlayer@ plr, int lod) {
	string desiredModel = getDesiredModel(plr);
	
	if (lod == LOD_HD) {
		return desiredModel;
	}
	
	if (g_model_list.exists(desiredModel)) {
		ModelInfo info = g_model_list.get(desiredModel);
		return lod == LOD_SD ? info.replacement_sd : info.replacement_ld;
	}
	
	return defaultLowpolyModel;
}

string getDesiredModel(CBaseEntity@ plr) {
	KeyValueBuffer@ p_PlayerInfo = g_EngineFuncs.GetInfoKeyBuffer( plr.edict() );
	return p_PlayerInfo.GetValue( "model" ).ToLowercase();
}

int getModelPolyCount(CBaseEntity@ plr, string model) {			
	int multiplier = plr.pev.renderfx == kRenderFxGlowShell ? 2 : 1;
		
	if (g_model_list.exists(model)) {
		return g_model_list.get(model).polys * multiplier;
	}
	
	return unknownModelPolys * multiplier; // assume the worst, to encourage adding models to the server
}

// flags models near this player which should be replaced with low poly models
void replace_highpoly_models(CBasePlayer@ looker, array<PlayerModelInfo>@ playerEnts, int totalPolys) {	
	PlayerState@ state = getPlayerState(looker);
	
	if (state.prefersHighPoly or state.modelSwapAll) {
		return; // player doesn't care if there are too many high-poly models on screen
	}

	int maxAllowedPolys = state.polyLimit;
	int reducedPolys = totalPolys;
	int lookeridx = looker.entindex();
	
	// reset vars to default because the array is shared with all players
	for (uint i = 0; i < playerEnts.size(); i++) {
		playerEnts[i].currentReplacement.lod = LOD_HD;
		playerEnts[i].replacePolys = playerEnts[i].desiredPolys;
		playerEnts[i].canReplace = !state.modelSwaps.exists(playerEnts[i].steamid);		
	}
	
	// Pick an LOD for ents in the PVS
	if (playerEnts.size() > 0 && totalPolys > maxAllowedPolys && !state.prefersHighPoly) {
		
		// SD pass. Do replacements from HD -> SD, but only if the model has an SD replacement.
		// Sort by poly count to replace highest polycount models first
		playerEnts.sort(function(a,b) { return a.desiredPolys > b.desiredPolys; });
		for (uint i = 0; i < playerEnts.size() && reducedPolys > maxAllowedPolys; i++) {		
			if (!playerEnts[i].hasOwner() or !playerEnts[i].canReplace or !playerEnts[i].canReplaceSd()) {
				continue;
			}
			
			playerEnts[i].currentReplacement.lod = LOD_SD;
			playerEnts[i].replacePolys = playerEnts[i].getReplacementPolys(true);
			
			reducedPolys -= playerEnts[i].desiredPolys - playerEnts[i].replacePolys;
		}
		
		// LD pass. Aggressively set to LD even if the model doesn't have an LD replacement.
		// Sort by polys again now that the SD pass has changed poly counts for each player
		playerEnts.sort(function(a,b) { return a.replacePolys > b.replacePolys; });
		for (uint i = 0; i < playerEnts.size() && reducedPolys > maxAllowedPolys; i++) {
			if (!playerEnts[i].hasOwner() or !playerEnts[i].canReplace) {
				continue;
			}
			
			// poly reduction doesn't stack. Undo the reduction from the SD pass.
			reducedPolys += playerEnts[i].desiredPolys - playerEnts[i].replacePolys; // 0 if no SD replacement was made
			
			playerEnts[i].currentReplacement.lod = LOD_LD;
			playerEnts[i].replacePolys = playerEnts[i].getReplacementPolys(false);
			
			// now apply the LD poly reduction
			reducedPolys -= playerEnts[i].desiredPolys - playerEnts[i].replacePolys;
		}
		
		// SD undo pass. Try to undo some SD model replacements, if an LD replacement freed up enough polys
		// Undo replacements for the lowest poly models first
		playerEnts.sort(function(a,b) { return a.replacePolys < b.replacePolys; });
		for (uint i = 0; i < playerEnts.size() && reducedPolys < maxAllowedPolys; i++) {
			if (!playerEnts[i].hasOwner() or !playerEnts[i].canReplace or playerEnts[i].currentReplacement.lod != LOD_SD) {
				continue;
			}
			
			int polysToAdd = playerEnts[i].desiredPolys - playerEnts[i].replacePolys;
			
			if (reducedPolys + polysToAdd > maxAllowedPolys) {
				continue;
			}

			playerEnts[i].currentReplacement.lod = LOD_HD;
			playerEnts[i].replacePolys = playerEnts[i].desiredPolys;
			
			reducedPolys += polysToAdd;
		}
	}
	
	// set LOD models on players/corpses/ghosts
	for (uint i = 0; i < playerEnts.size(); i++) {
		Replacement@ replacement = playerEnts[i].currentReplacement;
		CBaseEntity@ replaceEnt = replacement.h_ent;
		CBaseEntity@ replaceOwner = replacement.h_owner;
		
		if (replaceEnt is null or replaceOwner is null or !playerEnts[i].canReplace) {
			continue;
		}
			
		if (replaceEnt.IsPlayer()) {
			// player and deadplayer entity models are replaced via UserInfo messages
			CBasePlayer@ plr = cast<CBasePlayer@>(replaceOwner);
			string model = getLodModel(plr, replacement.lod);
			UserInfo info(plr);
			info.model = model;
			info.send(looker);
		} else {
			// ghost models are replaced by creating new LOD copies that are only visible to certain players
			GhostReplace@ ghostCopy = getGhostCopy(replaceEnt);
			ghostCopy.setLod(looker, replacement.lod);
		}
	}
}

// do .modelswap swaps
void do_modelswap_swaps(CBasePlayer@ looker, array<PlayerModelInfo>@ playerEnts) {
	PlayerState@ state = getPlayerState(looker);
	
	if (!state.modelSwapAll and state.modelSwaps.empty()) {
		return;
	}
	
	for (uint i = 0; i < playerEnts.size(); i++) {
		Replacement@ replacement = playerEnts[i].currentReplacement;
		CBaseEntity@ replaceEnt = replacement.h_ent;
		CBaseEntity@ replaceOwner = replacement.h_owner;
		
		if (replaceEnt is null or replaceOwner is null or replaceEnt.entindex() == looker.entindex()) {
			continue;
		}
			
		if (replaceEnt.IsPlayer()) {
			// player and deadplayer entity models are replaced via UserInfo messages
			CBasePlayer@ plr = cast<CBasePlayer@>(replaceOwner);
			
			if (state.modelSwapAll) {
				UserInfo info(plr);
				info.model = state.modelSwapAllModel;
				info.send(looker);
			}
			else if (state.modelSwaps.exists(playerEnts[i].steamid)) {
				string swap;
				state.modelSwaps.get(playerEnts[i].steamid, swap);
				
				UserInfo info(plr);
				info.model = swap;
				info.send(looker);
			}
		} else {
			// TODO: use a camera model to differentiate between hipoly swaps and personal swaps.
			// ideally the ghost model would be set to the model requested with .modelswap but
			// that would mean creating 32 copies of a ghost entity, for every player. that's
			// not worth the performance hit.
			if (state.modelSwapAll or state.modelSwaps.exists(playerEnts[i].steamid)) {
				GhostReplace@ ghostCopy = getGhostCopy(replaceEnt);
				ghostCopy.setLod(looker, LOD_LD);
			}
		}
	}
}

void check_if_swaps_needed() {
	if (g_paused) {
		return;
	}
	
	bool shouldDoSwaps = false;
	
	// check if any players updated settings which would undo per-client model replacements
	// this happens in the next loop because there needs to be a delay to ensure models are replaced
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {		
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected())
			continue;
		
		bool isObserver = plr.GetObserver().IsObserver();		
		string userInfo = UserInfo(plr).infoString();
		
		if (isObserver != g_wasObserver[i] || userInfo != g_cachedUserInfo[plr.entindex()]) {
			shouldDoSwaps = true;
		}
		
		g_cachedUserInfo[plr.entindex()] = userInfo;
		g_wasObserver[i] = isObserver;
	}
	
	if (shouldDoSwaps) {
		do_model_swaps(EHandle(null));
	}
}

void do_model_swaps(EHandle h_plr) {
	CBasePlayer@ forPlayer = cast<CBasePlayer@>(h_plr.GetEntity());
	
	int totalPolys;
	int totalPlayers;
	array<PlayerModelInfo> playerEnts = get_visible_players(totalPolys, totalPlayers);
	
	if (forPlayer is null or !forPlayer.IsConnected()) {
		for ( int i = 1; i <= g_Engine.maxClients; i++ ) {		
			CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
			
			if (plr is null or !plr.IsConnected())
				continue;
			
			replace_highpoly_models(plr, playerEnts, totalPolys);
			do_modelswap_swaps(plr, playerEnts);
		}
	} else {
		replace_highpoly_models(forPlayer, playerEnts, totalPolys);	
		do_modelswap_swaps(forPlayer, playerEnts);
	}
}

void check_model_names() {
	for( int i = 1; i <= g_Engine.maxClients; ++i ) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex( i );

		if (plr is null or !plr.IsConnected())
			continue;
		
		KeyValueBuffer@ pInfos = g_EngineFuncs.GetInfoKeyBuffer( plr.edict() );
		string currentModel = pInfos.GetValue( "model" ).ToLowercase();
		ModelInfo latest_info = g_model_list.get(currentModel);

		if (latest_info.officialName.Length() > 0 and latest_info.officialName != currentModel)  {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, 'Your model was changed to "' + latest_info.officialName + '" because "' + currentModel + '" is an alias or old version of the same model.\n');
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, 'If you see yourself as the helmet model, then wait for the next map. The server will send you ' + latest_info.officialName + '.\n');
			pInfos.SetValue( "model", latest_info.officialName );
		} else if (latest_info.officialName.Length() > 23) { // path to model would be longer than 64 characters (max file path length for precaching)
			PlayerState@ pstate = getPlayerState(plr);
			
			// wait a while in case player is still loading
			if ((g_Engine.time - pstate.lastJoinTime) > 60 and pstate.lastNagModel != latest_info.officialName) {
				pstate.lastNagModel = latest_info.officialName;
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, 'The name of your model "' + latest_info.officialName + '" is too long (23+ characters). The server can\'t share it with other players.\n');
			}
		}
	}
}

string formatInteger(int ival) {
	string val = "" + ival;
	string formatted;
	for (int i = int(val.Length())-1, k = 0; i >= 0; i--, k++) {
		if (k % 3 == 0 && k != 0) {
			formatted = "," + formatted;
		}
		formatted = "" + val[i] + formatted;
	}
	return formatted;
}

class ListInfo {
	string playerName;
	string modelName;
	string preference;
	string polyString;
	int polys; // -1 = unknown
}

void list_model_polys(CBasePlayer@ plr) {
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nPlayer Name              Model Name               Polygon Count        Preference\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '---------------------------------------------------------------------------------\n');

	array<ListInfo> mlist;

	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ lplr = g_PlayerFuncs.FindPlayerByIndex(i);
		if (lplr is null or !lplr.IsConnected())
			continue;
		
		PlayerState@ pstate = getPlayerState(lplr);
		
		string pname = lplr.pev.netname;
		string desiredModel = getDesiredModel(lplr);
		string modelName = desiredModel;
		
		// client crashes if printing this character
		if (int(modelName.Find("%n")) != -1) {
			modelName = modelName = "<INVALID>";
		}
		
		while (pname.Length() < 24) {
			pname += " ";
		}
		while (modelName.Length() < 24) {
			modelName += " ";
		}
		if (pname.Length() > 24) {
			pname = pname.SubString(0, 21) + "...";
		}
		if (modelName.Length() > 24) {
			modelName = modelName.SubString(0, 21) + "...";
		}
		
		ListInfo info;
		info.playerName = pname;
		info.modelName = modelName;
		info.preference = pstate.prefersHighPoly ? "HD" : "LD";
		info.polys = g_model_list.exists(desiredModel) ? int(g_model_list.get(desiredModel).polys) : -1;
		
		info.polyString = "??? (not installed)";
		if (info.polys != -1) {
			info.polyString = "" + formatInteger(info.polys);
		}
		
		while (info.polyString.Length() < 24) {
			info.polyString += " ";
		}
		
		mlist.insertLast(info);
	}
	
	mlist.sort(function(a,b) {
		int apolys = a.polys == -1 ? unknownModelPolys : a.polys;
		int bpolys = b.polys == -1 ? unknownModelPolys : b.polys;
		return apolys > bpolys;
	});
	
	int total_polys = 0;
	
	for (uint i = 0; i < mlist.size(); i++) {
		if (mlist[i].polys != -1) {
			total_polys += mlist[i].polys;
		} else {
			total_polys += unknownModelPolys;
		}
		
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 
			mlist[i].playerName + ' ' + mlist[i].modelName + ' ' + mlist[i].polyString + ' ' + mlist[i].preference + '\n');
	}
	
	PlayerState@ state = getPlayerState(plr);
	int perPlayerLimit = state.polyLimit / g_Engine.maxClients;
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '---------------------------------------------------------------------------------\n\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Total polys      = ' + formatInteger(total_polys) + '\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Your poly limit  = ' + formatInteger(state.polyLimit) + '\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Safe model polys = ' + formatInteger(perPlayerLimit) + '    (models below this limit will never be replaced)\n\n');
}

// find a player by name or partial name
CBasePlayer@ getPlayerByName(CBasePlayer@ caller, string name) {
	name = name.ToLowercase();
	int partialMatches = 0;
	CBasePlayer@ partialMatch;
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "player");
		if (ent !is null) {
			CBasePlayer@ plr = cast<CBasePlayer@>(ent);
			string plrName = string(plr.pev.netname).ToLowercase();
			if (plrName == name)
				return plr;
			else if (plrName.Find(name) != uint(-1))
			{
				@partialMatch = plr;
				partialMatches++;
			}
		}
	} while (ent !is null);
	
	if (partialMatches == 1) {
		return partialMatch;
	} else if (partialMatches > 1) {
		g_PlayerFuncs.SayText(caller, '[ModelSwap] Swap failed. There are ' + partialMatches + ' players that have "' + name + '" in their name. Be more specific.\n');
	} else {
		g_PlayerFuncs.SayText(caller, '[ModelSwap] Swap failed. There is no player named "' + name + '".\n');
	}
	
	return null;
}

bool doCommand(CBasePlayer@ plr, const CCommand@ args, bool isConsoleCommand=false) {
	PlayerState@ state = getPlayerState(plr);
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if ( args.ArgC() > 0 )
	{
		if (args[0] == ".listpoly") {
			list_model_polys(plr);
			return true;
		}
		else if (args[0] == ".modelswap") {
			if (args.ArgC() == 1) {
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "Force other players to use a model of your choice with this commands:\n");
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "    .modelswap [player] [model]\n");
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "[player] can be a Steam ID or incomplete name. Type \\ to target all players.\n");
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "[model] is the name of a model. Omit this to toggle/cancel a model swap.\n");
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "Model swaps are visible only to you.\n");
				return true;
			}
			
			string nicename;
			string targetid = args[1].ToLowercase();
			bool allPlayers = false;
			
			if (targetid.Find("\\") == 0) {
				allPlayers = true;
			}
			else if (targetid.Find("steam_0:") == 0) {
				nicename = targetid;
				nicename.ToUppercase();
			} else {
				CBasePlayer@ target = getPlayerByName(plr, targetid);
				
				if (target is null) {
					return true;
				}
				if (target.entindex() == plr.entindex()) {
					g_PlayerFuncs.SayText(plr, "[ModelSwap] Can't modelswap yourself.\n");
					return true;
				}	
				
				targetid = g_EngineFuncs.GetPlayerAuthId(target.edict());
				targetid = targetid.ToLowercase();
				nicename = target.pev.netname;
			}
			
			string newmodel = defaultLowpolyModel;
			if (args.ArgC() > 2) {
				newmodel = args[2];
			}
			bool shouldUnswap = args.ArgC() == 2;
			
			if (shouldUnswap and state.modelSwapAll) {
				state.modelSwapAll = false;
				state.modelSwapAllModel = "";
				state.modelSwaps.clear();
				reset_models(plr);
				do_model_swaps(plr);
				g_PlayerFuncs.SayText(plr, "[ModelSwap] Cancelled model swaps on all players.\n");
			}
			else if (allPlayers) {
				state.modelSwapAll = true;
				state.modelSwapAllModel = newmodel;
				state.modelSwaps.clear();
				do_model_swaps(plr);
				g_PlayerFuncs.SayText(plr, "[ModelSwap] Set model \"" + newmodel + "\" on all players.\n");
			} else {
				if (shouldUnswap and state.modelSwaps.exists(targetid)) {
					state.modelSwapAll = false;
					state.modelSwapAllModel = "";
					state.modelSwaps.delete(targetid);
					reset_models(plr);
					do_model_swaps(plr);
					g_PlayerFuncs.SayText(plr, "[ModelSwap] Cancelled model swap on player \"" + nicename + "\".\n");
				} else {
					state.modelSwapAll = false;
					state.modelSwapAllModel = "";
					state.modelSwaps[targetid] = newmodel;
					do_model_swaps(plr);
					g_PlayerFuncs.SayText(plr, "[ModelSwap] Set model \"" + newmodel + "\" on player \"" + nicename + "\".\n");
				}
			}	
	
			return true;
		}
		else if (args[0] == ".limitpoly") {
			float arg = Math.min(atof(args[1]), 1000);
			state.polyLimit = Math.max(int(arg*1000), 0);
			if (state.prefersHighPoly) {
				state.prefersHighPoly = false;
			}
			do_model_swaps(plr);
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Max model polys: " + formatInteger(state.polyLimit) + ".\n");
			return true;
		}
		else if (args[0] == ".hipoly") {
			if (args.ArgC() > 1) {
				if (args[1] == "pause" and isAdmin) {
					g_paused = !g_paused;
					g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[hipoly] " + plr.pev.netname + " " + (g_paused ? "paused" : "resumed") + " model replacements." + "\n");
					return true;
				}
				if (args[1] == "toggle") {
					state.prefersHighPoly = !state.prefersHighPoly;
				} else {
					state.prefersHighPoly = atoi(args[1]) != 0;
				}
				if (state.prefersHighPoly) {
					reset_models(plr);
					do_model_swaps(plr);
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Max player polys: Unlimited\n");
				}
				else {
					do_model_swaps(plr);
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Max player polys: " + formatInteger(state.polyLimit) + "\n");
				}
				return true;
			} else {
				if (!isConsoleCommand) {
					if (state.prefersHighPoly) {
						g_PlayerFuncs.SayText(plr, "Preference set to high-poly player models (worsens FPS).\n");
					}
					else {
						g_PlayerFuncs.SayText(plr, "Preference set to low-poly player models (improves FPS).\n");
					}
					
					g_PlayerFuncs.SayText(plr, 'Type ".hipoly" in console for more info\n');
				}
				string desiredModel = getDesiredModel(plr);
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '------------------------------Too Many Polys Plugin------------------------------\n\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'This plugin replaces high-poly player models with low-poly versions to improve FPS.\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nModels are replaced in order from most to least polygons, until the total player \n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'polygon count is below a limit that you set.\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nLooking for models with a low poly count? Try here:\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'https://wootguy.github.io/scmodels/\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nCommands:\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".hipoly [0/1/toggle]" to toggle model replacement on/off.\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".limitpoly X" to change the polygon limit (X = poly count, in thousands).\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".listpoly" to list each player\'s desired model and polygon count.\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".modelswap" to force other players to use a model of your choice, ignoring polygon count.\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nStatus:\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Your preference is for ' + (state.prefersHighPoly ? "high-poly" : "low-poly") +' models.\n');
				
				ModelInfo info = g_model_list.get(desiredModel);
				
				if (g_model_list.exists(desiredModel)) {
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Your model\'s detail levels:\n');
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        HD Model: ' + desiredModel + ' (' + formatInteger(info.polys) + ' polys)\n');
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        SD Model: ' + info.replacement_sd + ' (' + formatInteger(g_model_list.get(info.replacement_sd).polys) + ' polys)\n');
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        LD Model: ' + info.replacement_ld + ' (' + formatInteger(g_model_list.get(info.replacement_ld).polys) + ' polys)\n');
				}
				else {
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Your player model (' + desiredModel + ') is not installed on this server.\n');
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        Because of this, your player model is assumed to have an insanely high\n');
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        poly count (' + formatInteger(unknownModelPolys) +').\n');
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Your model\'s detail levels:\n');
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        HD Model: ' + desiredModel + ' (' + formatInteger(unknownModelPolys) + ' polys)\n');
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        SD Model: ' + defaultLowpolyModel + ' (' + formatInteger(defaultLowpolyModelPolys) + ' polys)\n');
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        LD Model: ' + defaultLowpolyModel + ' (' + formatInteger(defaultLowpolyModelPolys) + ' polys)\n');
				}
				int perPlayerLimit = state.polyLimit / g_Engine.maxClients;
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Your visible polygon limit is set to ' 
					+ formatInteger(state.polyLimit) + ' (' + formatInteger(perPlayerLimit) + ' per player).\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\n---------------------------------------------------------------------------------\n\n');
				
			}
			return true;
		}
	}
	return false;
}

HookReturnCode ClientSay( SayParameters@ pParams ) {
	CBasePlayer@ plr = pParams.GetPlayer();
	const CCommand@ args = pParams.GetArguments();	
	
	if (doCommand(plr, args, false))
		pParams.ShouldHide = true;
		
	return HOOK_CONTINUE;
}

CClientCommand _hipoly("hipoly", "Too Many Polys command", @consoleCmd );
CClientCommand _listpoly("listpoly", "Too Many Polys command", @consoleCmd );
CClientCommand _debugpoly("debugpoly", "Too Many Polys command", @consoleCmd );
CClientCommand _polylimit("limitpoly", "Too Many Polys command", @consoleCmd );
CClientCommand _modelswap("modelswap", "Too Many Polys command", @consoleCmd );

void consoleCmd( const CCommand@ args ) {
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args, true);
}