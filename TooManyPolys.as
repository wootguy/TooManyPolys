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
	
	int debug;
	int debugPolys;
	int debugReducedPolys;
	int debugVisiblePlayers;
	int debugTotalPlayers;
}

string g_model_list_path = "scripts/plugins/TooManyPolys/models.txt";
string g_alias_list_path = "scripts/plugins/TooManyPolys/aliases.txt";
const int hashmapBucketCount = 4096;
HashMapModelInfo g_model_list(hashmapBucketCount);
CCVar@ cvar_default_poly_limit;
dictionary g_player_states;

const string defaultLowpolyModel = "player-10up";
const string defaultLowpolyModelPath = "models/player/" + defaultLowpolyModel + "/" + defaultLowpolyModel + ".mdl";
const int defaultLowpolyModelPolys = 142;
const int unknownModelPolys = 50000; // assume the worst (better not to risk lowering FPS)

const string moreInfoMessage = "Type '.hipoly' in console for more info.";

array<array<Replacement>> g_replacements(33); // player idx -> current LOD seen for other players and ghosts
array<string> g_cachedUserInfo(33); // used to detect when user info has changed, which undos model replacement
array<GhostReplace> g_ghostCopys;
array<string> g_precachedModels;
array<bool> g_forceUpdateClients(33);
array<bool> g_wasObserver(33);

class Replacement {
	EHandle h_ent; // entity being replaced
	EHandle h_owner; // player which owns the entity (to know which model is used)
	int lod = LOD_HD; // current level of detail
}

void PluginInit() {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "asdf" );
	
	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @ClientSay );
	g_Hooks.RegisterHook( Hooks::Player::ClientPutInServer, @ClientJoin );
	g_Hooks.RegisterHook( Hooks::Player::PlayerEnteredObserver, @PlayerEnteredObserver );
	g_Hooks.RegisterHook( Hooks::Game::MapChange, @MapChange );
	
	@cvar_default_poly_limit = CCVar("default_poly_limit", 32000, "max player visble polys", ConCommandFlag::AdminOnly);
	
	load_model_list();
	
	g_Scheduler.SetInterval("update_models", 0.1, -1);
	g_Scheduler.SetInterval("check_model_names", 1.0, -1);
	g_Scheduler.SetInterval("update_ghost_models", 0.05, -1);
	
	loadPrecachedModels();
}

void PluginExit() {
	reset_models();
}

void MapInit() {
	precachePlayerModels();
	
	for (uint i = 0; i < 33; i++) {
		g_wasObserver[i] = false;
		g_cachedUserInfo[i] = "";
		g_forceUpdateClients[i] = false;
	}
	
	g_replacements.resize(0);
	g_replacements.resize(33);
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
	addPlayerModel(plr);

	for (uint i = 0; i < g_ghostCopys.size(); i++) {
		g_ghostCopys[i].setLod(plr, LOD_HD);
	}

	return HOOK_CONTINUE;
}

HookReturnCode MapChange() {
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
		addPlayerModel(g_PlayerFuncs.FindPlayerByIndex(i));
	}

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

bool isPlayerVisible(Vector lookerOrigin, Vector lookDirection, CBaseEntity@ plr) {
	if ((plr.pev.effects & EF_NODRAW) == 0 && (plr.pev.rendermode == 0 || plr.pev.renderamt > 0)) {
		Vector delta = (plr.pev.origin - lookerOrigin).Normalize();
		
		// check if player is in fov of the looker (can't actually check the fov of a player so this assumes 180 degrees)
		bool isVisible = DotProduct(delta, g_Engine.v_forward) > 0.0;
		
		if (isVisible) {
			return true;
		}
	}
	
	return false;
}

array<PlayerModelInfo> get_visible_players(CBasePlayer@ looker, int&out totalPolys, int&out totalPlayers) {	
	Math.MakeVectors( looker.pev.v_angle );
	Vector lookerOrigin = looker.pev.origin - g_Engine.v_forward * 128; // assume chasecam is on
	
	array<PlayerModelInfo> pvsPlayerInfos;
	array<CBaseEntity@> pvsPlayers;
	bool canSeeAnyPlayers = false;
	
	//edict_t@ edt = @g_EngineFuncs.EntitiesInPVS(@g_EntityFuncs.Instance(0).edict()); // useless, see HLEnhanced comment
	edict_t@ edt = @g_EngineFuncs.EntitiesInPVS(@looker.edict());
	
	while (edt !is null)
	{
		CBaseEntity@ ent = g_EntityFuncs.Instance( edt );
		if (ent is null) {
			break;
		}
		@edt = @ent.pev.chain;
		
		CBasePlayer@ plr = cast<CBasePlayer@>(ent);
		
		if (plr !is null && plr.IsConnected() && !plr.GetObserver().IsObserver()) {
			canSeeAnyPlayers = true;
			pvsPlayers.insertLast(ent);
		} else if (string(ent.pev.classname) == "deadplayer") {
			pvsPlayers.insertLast(ent);
		}
		else if (string(ent.pev.targetname).Find("plugin_ghost_cam_") == 0 and string(ent.pev.model) != "models/as_ghosts/camera.mdl") {
			if (isGhostVisible(ent, looker)) {
				pvsPlayers.insertLast(ent);
			}
		}
	}
	
	if (!canSeeAnyPlayers) {
		// map has no VIS info, so assume everyone is in the PVS
		// for reason corpses will still be added to the pvs list properly, so no need to add those too
		for ( int i = 1; i <= g_Engine.maxClients; i++ ) {		
			CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
			
			if (plr is null or !plr.IsConnected() or plr.GetObserver().IsObserver())
				continue;
			
			pvsPlayers.insertLast(plr);
		}
	}
	
	totalPolys = 0;
	for (uint i = 0; i < pvsPlayers.size(); i++) {
		CBaseEntity@ plr = pvsPlayers[i];
		
		if (isPlayerVisible(lookerOrigin, g_Engine.v_forward, plr)) {
			PlayerModelInfo info;
			CBaseEntity@ modelPlr = plr;
		
			// if this is a body, find who owns it
			if (string(plr.pev.classname) == "deadplayer") {
				CustomKeyvalues@ pCustom = plr.GetCustomKeyvalues();
				CustomKeyvalue ownerKey( pCustom.GetKeyvalue( "$i_hipoly_owner" ) );
				bool hasOwner = false;
				
				if (ownerKey.Exists()) {
					CBasePlayer@ owner = g_PlayerFuncs.FindPlayerByIndex(ownerKey.GetInteger());
					
					if (owner !is null and owner.IsConnected()) {
						@info.owner = @owner;
						@modelPlr = @owner;
						hasOwner = true;
					}
				}
				if (!hasOwner) {
					println("Failed to find owner for corpse");
				}
			}
			if (string(plr.pev.targetname).Find("plugin_ghost_cam_") == 0) {
				CBasePlayer@ owner = g_PlayerFuncs.FindPlayerByIndex(plr.pev.iuser2);
				if (owner !is null) {
					@info.owner = @owner;
					@modelPlr = @owner;
				} else {
					println("Failed to find owner for ghost");
				}
			}
		
			@info.ent = @plr;
			info.desiredModel = getDesiredModel(modelPlr);
			info.desiredPolys = getModelPolyCount(modelPlr, info.desiredModel);
			info.replacePolys = info.desiredPolys;
			info.currentReplacement.h_ent = EHandle(info.ent);
			info.currentReplacement.h_owner = EHandle(info.getOwner());	
			pvsPlayerInfos.insertLast(info);
			totalPolys += info.desiredPolys;
		}
	}
	
	totalPlayers = pvsPlayers.size();
	
	return pvsPlayerInfos;
}

void reset_models(CBasePlayer@ forPlayer=null) {
	if (forPlayer !is null) {
		int eidx = forPlayer.entindex();
		
		for (uint i = 0; i < g_replacements[eidx].size(); i++) {
			CBaseEntity@ replaceEnt = g_replacements[eidx][i].h_ent;
			if (replaceEnt is null) {
				continue;
			}
			
			if (replaceEnt.pev.classname == "cycler") {
				GhostReplace@ ghostCopy = getGhostCopy(replaceEnt);
				ghostCopy.setLod(forPlayer, LOD_HD);
			} else {
				CBasePlayer@ owner = cast<CBasePlayer@>(g_replacements[eidx][i].h_owner.GetEntity());
				if (owner !is null) {
					UserInfo(owner).send(forPlayer);
				}
			}
		}
		
		g_replacements[forPlayer.entindex()].resize(0);
	}
	else {
		for ( int i = 1; i <= g_Engine.maxClients; i++ )
		{
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
		
		g_replacements.resize(0);
		g_replacements.resize(33);
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
void replace_highpoly_models(CBasePlayer@ looker, array<bool>@ g_forceUpdateClients) {	
	PlayerState@ state = getPlayerState(looker);
	
	if (state.prefersHighPoly and state.debug == 0) {
		return; // player doesn't care if there are too many high-poly models on screen
	}

	int totalPolys = 0;
	int totalPlayers = 0;
	array<PlayerModelInfo> pvsPlayers = get_visible_players(looker, totalPolys, totalPlayers);
	int maxAllowedPolys = state.polyLimit;
	int reducedPolys = totalPolys;
	array<Replacement> oldReplacements;
	int lookeridx = looker.entindex();
	
	for (uint i = 0; i < g_replacements[lookeridx].size(); i++) {
		oldReplacements.insertLast(g_replacements[lookeridx][i]);
	}
	
	// Pick an LOD for ents in the PVS
	if (pvsPlayers.size() > 0 && totalPolys > maxAllowedPolys && !state.prefersHighPoly) {
		
		// SD pass. Do replacements from HD -> SD, but only if the model has an SD replacement.
		// Sort by poly count to replace highest polycount models first
		pvsPlayers.sort(function(a,b) { return a.desiredPolys > b.desiredPolys; });
		for (uint i = 0; i < pvsPlayers.size() && reducedPolys > maxAllowedPolys; i++) {		
			if (!pvsPlayers[i].hasOwner() or !pvsPlayers[i].canReplaceSd()) {
				continue;
			}
			
			pvsPlayers[i].currentReplacement.lod = LOD_SD;
			pvsPlayers[i].replacePolys = pvsPlayers[i].getReplacementPolys(true);
			
			reducedPolys -= pvsPlayers[i].desiredPolys - pvsPlayers[i].replacePolys;
		}
		
		// LD pass. Aggressively set to LD even if the model doesn't have an LD replacement.
		// Sort by polys again now that the SD pass has changed poly counts for each player
		pvsPlayers.sort(function(a,b) { return a.replacePolys > b.replacePolys; });
		for (uint i = 0; i < pvsPlayers.size() && reducedPolys > maxAllowedPolys; i++) {
			if (!pvsPlayers[i].hasOwner()) {
				continue;
			}
			
			// poly reduction doesn't stack. Undo the reduction from the SD pass.
			reducedPolys += pvsPlayers[i].desiredPolys - pvsPlayers[i].replacePolys; // 0 if no SD replacement was made
			
			pvsPlayers[i].currentReplacement.lod = LOD_LD;
			pvsPlayers[i].replacePolys = pvsPlayers[i].getReplacementPolys(false);
			
			// now apply the LD poly reduction
			reducedPolys -= pvsPlayers[i].desiredPolys - pvsPlayers[i].replacePolys;
		}
		
		// SD undo pass. Try to undo some SD model replacements, if an LD replacement freed up enough polys
		// Undo replacements for the lowest poly models first
		pvsPlayers.sort(function(a,b) { return a.replacePolys < b.replacePolys; });
		for (uint i = 0; i < pvsPlayers.size() && reducedPolys < maxAllowedPolys; i++) {
			if (!pvsPlayers[i].hasOwner() or pvsPlayers[i].currentReplacement.lod != LOD_SD) {
				continue;
			}
			
			int polysToAdd = pvsPlayers[i].desiredPolys - pvsPlayers[i].replacePolys;
			
			if (reducedPolys + polysToAdd > maxAllowedPolys) {
				continue;
			}

			pvsPlayers[i].currentReplacement.lod = LOD_HD;
			pvsPlayers[i].replacePolys = pvsPlayers[i].desiredPolys;
			
			reducedPolys += polysToAdd;
		}
	}
	
	g_replacements[lookeridx].resize(0);
	g_replacements[lookeridx].resize(pvsPlayers.size());
	for (uint i = 0; i < pvsPlayers.size(); i++) {
		g_replacements[lookeridx][i] = pvsPlayers[i].currentReplacement;
	}
	
	// update LOD for ents in the PVS
	for (uint i = 0; i < g_replacements[lookeridx].size(); i++) {
		Replacement@ replacement = g_replacements[lookeridx][i];
		CBaseEntity@ replaceEnt = replacement.h_ent;
		CBaseEntity@ replaceOwner = replacement.h_owner;
		
		if (replaceEnt is null) {
			continue;
		}
		
		int currentLod = replacement.lod;
		int oldLod = LOD_HD;
		
		bool foundOld = false;
		for (uint k = 0; k < oldReplacements.size(); k++) {
			CBaseEntity@ oldReplaceEnt = oldReplacements[k].h_ent;
			if (oldReplaceEnt is null) {
				continue;
			}
			if (oldReplaceEnt.entindex() == replaceEnt.entindex()) {
				oldLod = oldReplacements[k].lod;
				oldReplacements[k].lod = -1; // special value that means this oldReplacement is still tracked
				foundOld = true;
				break;
			}
		}
		
		bool playerModelUpdated = g_forceUpdateClients[replaceOwner.entindex()];
		
		if (oldLod != currentLod or playerModelUpdated) {
			//println("UPDATE " + replaceEnt.pev.classname + " " + replaceOwner.pev.netname + " " + currentLod);
			
			if (replaceEnt.IsPlayer() or replaceEnt.pev.classname == "deadplayer") {
				// player and deadplayer entity models are replaced via UserInfo messages
				CBasePlayer@ plr = cast<CBasePlayer@>(replaceOwner);
				string model = getLodModel(plr, currentLod);
				UserInfo info(plr);
				info.model = model;
				info.send(looker);
			} else {
				// ghost models are replaced by creating new LOD copies that are only visible to certain players
				GhostReplace@ ghostCopy = getGhostCopy(replaceEnt);
				ghostCopy.setLod(looker, currentLod);
			}
		}
	}
	
	// revert LOD for ents that are no longer in the PVS
	for (uint i = 0; i < oldReplacements.size(); i++) {
		Replacement@ replacement = oldReplacements[i];
		CBaseEntity@ replaceEnt = replacement.h_ent;
		CBaseEntity@ replaceOwner = replacement.h_owner;
		
		if (replaceEnt is null) {
			continue;
		}
		
		if (oldReplacements[i].lod != -1) {
			//println("REVERT " + replaceEnt.pev.classname + " " + replaceOwner.pev.netname);
			
			if (replaceEnt.IsPlayer() or replaceEnt.pev.classname == "deadplayer") {
				// player and deadplayer entity models are replaced via UserInfo messages
				CBasePlayer@ plr = cast<CBasePlayer@>(replaceOwner);
				string model = getLodModel(plr, LOD_HD);
				UserInfo info(plr);
				info.model = model;
				info.send(looker);
			} else {
				// ghost models are replaced by creating new LOD copies that are only visible to certain players
				GhostReplace@ ghostCopy = getGhostCopy(replaceEnt);
				ghostCopy.setLod(looker, LOD_HD);
			}
		}
	}
	
	state.debugPolys = totalPolys;
	state.debugReducedPolys = reducedPolys;
	state.debugVisiblePlayers = pvsPlayers.size();
	state.debugTotalPlayers = totalPlayers;
}

void debug(CBasePlayer@ plr) {
	PlayerState@ state = getPlayerState(plr);
		
	if (state.debug > 0) {
		HUDTextParams params;
		params.effect = 0;
		params.fadeinTime = 0;
		params.fadeoutTime = 0.1;
		params.holdTime = 1.5f;
		
		params.x = -1;
		params.y = 0.99;
		params.channel = 1;
		
		string info = "Players models: " + state.debugVisiblePlayers + " / " + state.debugTotalPlayers;
		info += "\nPolys: " + formatInteger(state.debugPolys);
		if (state.debugPolys != state.debugReducedPolys)
			info += " --> " + formatInteger(state.debugReducedPolys);
		info += "\nReplaced: ";
		
		int eidx = plr.entindex();
		bool anyReplaced = false;
		
		for (uint i = 0; i < g_replacements[eidx].size(); i++) {
			int lod = g_replacements[eidx][i].lod;
			if (lod == LOD_HD) {
				continue;
			}
			
			CBaseEntity@ target = g_replacements[eidx][i].h_ent;
			CBaseEntity@ owner = g_replacements[eidx][i].h_owner;
			if (target is null)
				continue;

			if (state.debug > 1) {
				Vector lookerPos = plr.pev.origin + plr.pev.view_ofs - Vector(0,0,5);
				Vector targetPos = target.pev.origin;
				
				Color color = lod == LOD_SD ? YELLOW : RED;
				te_beampoints(lookerPos, targetPos, "sprites/laserbeam.spr", 0, 0, 1, 2, 0, color, 32, MSG_ONE_UNRELIABLE, plr.edict());
			}
			
			if (anyReplaced) {
				info += ", ";
			}
			info += getDesiredModel(owner) + " " + (lod == LOD_SD ? "(SD)" : "(LD)");
			anyReplaced = true;
		}
		
		if (!anyReplaced) {
			info += "none";
		}
		
		if (info.Length() > 300) {
			info = info.SubString(0, 297) + "...";
		}
		
		g_PlayerFuncs.HudMessage(plr, params, info);
	}
}

void update_models() {
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {		
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected())
			continue;
		
		replace_highpoly_models(plr, g_forceUpdateClients);	
		debug(plr);
	}
	
	// check if any players updated settings which would undo per-client model replacements
	// this happens in the next loop because there needs to be a delay to ensure models are replaced
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
		g_forceUpdateClients[i] = false;
		
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected())
			continue;
		
		bool isObserver = plr.GetObserver().IsObserver();		
		string userInfo = UserInfo(plr).infoString();
		
		if (isObserver != g_wasObserver[i] || userInfo != g_cachedUserInfo[plr.entindex()]) {
			g_forceUpdateClients[i] = true;
		}
		
		g_cachedUserInfo[plr.entindex()] = userInfo;
		g_wasObserver[i] = isObserver;
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
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, 'Your model was changed to "' + latest_info.officialName + '" because "' + currentModel + '" is an unofficial name or old version.\n');
			pInfos.SetValue( "model", latest_info.officialName );
		} else if (latest_info.officialName.Length() == 0) {
			// model not installed on server
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

bool doCommand(CBasePlayer@ plr, const CCommand@ args, bool isConsoleCommand=false) {
	PlayerState@ state = getPlayerState(plr);
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if ( args.ArgC() > 0 )
	{
		if (args[0] == ".listpoly") {
			list_model_polys(plr);
			return true;
		}
		else if (args[0] == ".debugpoly") {
			if (args.ArgC() > 1) {
				int arg = atoi(args[1]);
				state.debug = arg;
			} else {
				state.debug = state.debug > 0 ? 0 : 2;
			}
			string mode = "DISABLED";
			if (state.debug == 1) {
				mode = "ENABLED";
			} else if (state.debug > 1) {
				mode = "ENABLED (with lasers)";
			}
			
			g_PlayerFuncs.SayText(plr, 'Poly count debug mode ' + mode + '\n');
			return true;
		}
		else if (args[0] == ".limitpoly") {
			float arg = Math.min(atof(args[1]), 1000);
			state.polyLimit = Math.max(int(arg*1000), defaultLowpolyModelPolys*g_Engine.maxClients);
			if (!state.prefersHighPoly) {
				state.prefersHighPoly = false;
			}
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Max player polys: " + formatInteger(state.polyLimit) + "\n");
			return true;
		}
		else if (args[0] == ".hipoly") {
			if (args.ArgC() > 1) {
				if (args[1] == "toggle") {
					state.prefersHighPoly = !state.prefersHighPoly;
				} else {
					state.prefersHighPoly = atoi(args[1]) != 0;
				}
				if (state.prefersHighPoly) {
					reset_models(plr);
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Max player polys: Unlimited\n");
				}
				else {
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
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nModels are replaced in order from most to least polygons, until the visible \n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'polygon count is below a limit that you set.\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nLooking for models with a low poly count? Try here:\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'https://wootguy.github.io/scmodels/\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nCommands:\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".hipoly [0/1/toggle]" to toggle model replacement on/off.\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".limitpoly X" to change the polygon limit (X = poly count, in thousands).\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".listpoly" to list each player\'s desired model and polygon count.\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".debugpoly [0/1/2]" to show:\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        - How many player model polys the server thinks you can see.\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        - List of players who are having their models replaced\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        - Lasers showing which models are replaced (mode 2 only)\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '              No line = HD model (not replaced)\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '              Yellow  = SD model\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '              Red     = LD model\n');
				
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

void consoleCmd( const CCommand@ args ) {
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args, true);
}