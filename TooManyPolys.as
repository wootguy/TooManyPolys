#include "HashMap"
#include "UserInfo"
#include "util"

// TODO:
// - performance improvements?
// - replace ghost models somehow
// - angles dont work while dead
// - special characters in names mess up .listpoly table alignment
// - replace knuckles models with 2d
// - re-apply replacement when changing a userinfo setting

// can't reproduce:
// - vis checks don't work sometimes:
//   - only on map start? Not until everyone connected with non-0 ping?
//   - only the spawn area? (hunger, rc_labyrinth)

void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

class ModelInfo {
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
	
	bool debug;
	int debugPolys;
	int debugReducedPolys;
	int debugVisiblePlayers;
	int debugTotalPlayers;
}

string model_list_path = "scripts/plugins/TooManyPolys/models.txt";
const int hashmapBucketCount = 4096;
HashMapModelInfo g_model_list(hashmapBucketCount);
CCVar@ cvar_default_poly_limit;
dictionary g_player_states;

const string defaultLowpolyModel = "player-10up";
const int defaultLowpolyModelPolys = 142;
const int unknownModelPolys = 50000; // assume the worst (better not to risk lowering FPS)

const string moreInfoMessage = "Type '.hipoly' in console for more info.";

array<string> g_ModelList; // list of models to precache
array<array<int>> g_replacers; // player idx -> current LOD seen for other players
array<string> g_cachedUserInfo; // used to detect when user info has changed, which undos model replacement

void PluginInit() {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "asdf" );
	
	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @ClientSay );
	g_Hooks.RegisterHook( Hooks::Player::PlayerEnteredObserver, @PlayerEnteredObserver );
	
	@cvar_default_poly_limit = CCVar("default_poly_limit", 32000, "max player visble polys", ConCommandFlag::AdminOnly);
	
	g_Hooks.RegisterHook( Hooks::Player::ClientPutInServer, @ClientJoin );
	
	load_model_list();
	
	g_Scheduler.SetInterval("update_models", 0.1, -1);
	
	g_replacers.resize(33);
	g_cachedUserInfo.resize(33);
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
		g_replacers[i].resize(33);
	}
}

void PluginExit() {
	reset_models();
}

void MapInit() {
	array<string> precachedModels;

	// copied from PlayerModelPrecacheDyn
	for ( uint i = 0; i < g_ModelList.length(); i++ ) {
		File@ pFile = g_FileSystem.OpenFile( "scripts/plugins/store/playermodelfolder/" + g_ModelList[i] + "/" + g_ModelList[i] + ".mdl", OpenFile::READ );

		if ( pFile !is null && pFile.IsOpen() ) {
			pFile.Close();
			g_Game.PrecacheModel( "models/player/" + g_ModelList[i] + "/" + g_ModelList[i] + ".mdl" );
			precachedModels.insertLast(g_ModelList[i]);
		}

		File@ pFileT = g_FileSystem.OpenFile( "scripts/plugins/store/playermodelfolder/" + g_ModelList[i] + "/" + g_ModelList[i] + "t.mdl", OpenFile::READ );

		if ( pFileT !is null && pFileT.IsOpen() ) {
			pFileT.Close();
			g_Game.PrecacheGeneric( "models/player/" + g_ModelList[i] + "/" + g_ModelList[i] + "t.mdl" );
		}

		File@ pFileP = g_FileSystem.OpenFile( "scripts/plugins/store/playermodelfolder/" + g_ModelList[i] + "/" + g_ModelList[i] + ".bmp", OpenFile::READ );

		if ( pFileP !is null && pFileP.IsOpen() ) {
			pFileP.Close();
			g_Game.PrecacheGeneric( "models/player/" + g_ModelList[i] + "/" + g_ModelList[i] + ".bmp" );
		}
	}

	// create an ent to share the model list with other plugins
	dictionary keys;
	keys["targetname"] = "TooManyPolys";
	for (uint i = 0; i < precachedModels.size(); i++) {
		keys["$s_model" + i] = precachedModels[i];
	}
	g_EntityFuncs.CreateEntity("info_target", keys, true);		

	g_ModelList.resize( 0 );
	g_ModelList.insertLast(defaultLowpolyModel);
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
	KeyValueBuffer@ p_PlayerInfo = g_EngineFuncs.GetInfoKeyBuffer( plr.edict() );

	if ( g_ModelList.find( p_PlayerInfo.GetValue( "model" ) ) < 0 ) {
		int res = p_PlayerInfo.GetValue( "model" ).FindFirstOf( "/" );

		if ( res < 0 ) {
			string lowermodel = p_PlayerInfo.GetValue( "model" ).ToLowercase();
			g_ModelList.insertLast( lowermodel );
			
			if (g_model_list.exists(lowermodel)) { // also precache the low-poly versions
				ModelInfo info = g_model_list.get(lowermodel);
				
				if (g_ModelList.find(info.replacement_sd) < 0)
					g_ModelList.insertLast(info.replacement_sd);
					
				if (g_ModelList.find(info.replacement_ld) < 0)
					g_ModelList.insertLast(info.replacement_ld);
			}
		}
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
	
	File@ f = g_FileSystem.OpenFile( model_list_path, OpenFile::READ );
	if (f is null or !f.IsOpen())
	{
		println("TooManyPolys: Failed to open " + model_list_path);
		return;
	}
	
	int modelCount = 0;
	string line;
	while( !f.EOFReached() )
	{
		f.ReadLine(line);
		line.Trim();
		line.Trim("\t");
		if (line.Length() == 0 or line.Find("//") == 0)
			continue;
		
		array<string> parts = line.Split("/");
		if (parts.size() < 4) {
			println("TooManyPolys: Failed to parse model info: " + line);
			continue;
		}
		for (int i = 0; i < 4; i++) {
			parts[i].Trim();
			
			if (parts[i][0] == ' ') { // because Trim doesn't actually work
				parts[i] = '';
			}
		}
		string model_name = parts[0];
		int poly_count = atoi(parts[1]);
		string sd_model = parts[2];
		string ld_model = parts[3];
		//println("LOAD " + model_name + " " + poly_count + " " + replace_model);
		
		ModelInfo info;
		info.polys = poly_count;
		info.replacement_sd = sd_model.Length() > 0 ? sd_model : defaultLowpolyModel;
		info.replacement_ld = ld_model.Length() > 0 ? ld_model : defaultLowpolyModel;
		
		g_model_list.put(model_name, info);
		modelCount++;
	}
	
	println("TooManyPolys: Loaded " + modelCount + " models from " + model_list_path);
	
	g_model_list.stats();
}

class PlayerModelInfo {
	CBaseEntity@ plr;
	CBasePlayer@ owner; // if plr is a dead body, then this is the owning player
	string desiredModel;
	int desiredPolys;
	int replacePolys;
	
	PlayerModelInfo() {}
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
					println("Failed to find owner for corpse.");
				}
			}
		
			@info.plr = @plr;
			info.desiredModel = getDesiredModel(modelPlr);
			info.desiredPolys = getModelPolyCount(modelPlr, info.desiredModel);
			pvsPlayerInfos.insertLast(info);
			totalPolys += info.desiredPolys;
		}
	}
	
	totalPlayers = pvsPlayers.size();
	
	return pvsPlayerInfos;
}

void reset_models(CBasePlayer@ forPlayer=null) {
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		if (plr is null or !plr.IsConnected())
			continue;
		
		if (forPlayer !is null) {
			UserInfo(plr).send(forPlayer);
		} else {
			UserInfo(plr).broadcast();
		}
	}
	
	if (forPlayer !is null) {
		g_replacers[forPlayer.entindex()].resize(0);
		g_replacers[forPlayer.entindex()].resize(33);
	} else {
		g_replacers.resize(0);
		g_replacers.resize(33);
		
		for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
			g_replacers[i].resize(33);
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
void replace_highpoly_models(CBasePlayer@ looker, array<bool>@ forceUpdateClients) {	
	PlayerState@ state = getPlayerState(looker);
	
	if (state.prefersHighPoly and not state.debug) {
		return; // player doesn't care if there are too many high-poly models on screen
	}

	int totalPolys = 0;
	int totalPlayers = 0;
	array<PlayerModelInfo> pvsPlayers = get_visible_players(looker, totalPolys, totalPlayers);
	int maxAllowedPolys = state.polyLimit;
	int reducedPolys = totalPolys;
	array<int> oldLod(33);
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		if (plr is null or !plr.IsConnected())
			continue;
	
		oldLod[i] = g_replacers[looker.entindex()][plr.entindex()];
		g_replacers[looker.entindex()][plr.entindex()] = LOD_HD;
	}
	
	if (pvsPlayers.size() > 0 && totalPolys > maxAllowedPolys && !state.prefersHighPoly) {
		
		// replace highest polycount models first
		pvsPlayers.sort(function(a,b) { return a.desiredPolys > b.desiredPolys; });
		
		for (int pass = 0; pass < 2 && reducedPolys > maxAllowedPolys; pass++) {
			bool sd_model_replacement_only = pass == 0;
			
			if (pass == 1) {
				// sort again now that HD models have been replaced with SD models
				pvsPlayers.sort(function(a,b) { return a.desiredPolys > b.desiredPolys; });
			}
		
			for (uint i = 0; i < pvsPlayers.size() && reducedPolys > maxAllowedPolys; i++) {
				CBaseEntity@ plr = pvsPlayers[i].plr;
				int eidx = plr.entindex();
				
				if (plr.pev.classname == "deadplayer") {
					if (pvsPlayers[i].owner !is null) {
						eidx = pvsPlayers[i].owner.entindex();
					} else {
						println("Can't replace model for corpse with no owner");
						continue;
					}
				}
				
				int multiplier = plr.pev.renderfx == kRenderFxGlowShell ? 2 : 1;
				int replacePolys = defaultLowpolyModelPolys * multiplier;
				
				if (g_model_list.exists(pvsPlayers[i].desiredModel)) {
					ModelInfo info = g_model_list.get(pvsPlayers[i].desiredModel);
				
					if (sd_model_replacement_only && !info.hasSdModel()) {
						continue; // first pass only forces SD models on each player
					}
				
					string replace_model = sd_model_replacement_only ? info.replacement_sd : info.replacement_ld;
					ModelInfo replaceInfo = g_model_list.get(replace_model);
					
					replacePolys = replaceInfo.polys * multiplier;
					if (pvsPlayers[i].desiredPolys < replacePolys) {
						println("Replacement model is higher poly! (" + pvsPlayers[i].desiredModel + " -> " + replace_model);
					}
					
				} else {
					if (sd_model_replacement_only) {
						continue; // missing models have no SD varient
					}
				}
				
				int newLod = sd_model_replacement_only ? LOD_SD : LOD_LD;
				int lastPassLod = g_replacers[looker.entindex()][eidx];
				g_replacers[looker.entindex()][eidx] = newLod;
				
				reducedPolys -= (pvsPlayers[i].desiredPolys - replacePolys);
				if (lastPassLod != LOD_HD) {
					// poly reduction doesn't stack. Undo the reduction from the previous pass.
					reducedPolys += (pvsPlayers[i].desiredPolys - pvsPlayers[i].replacePolys);
				}
				pvsPlayers[i].replacePolys = replacePolys;
				pvsPlayers[i].desiredPolys = replacePolys;
			}
		}
	}
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		if (plr is null or !plr.IsConnected())
			continue;
			
		int currentLod = g_replacers[looker.entindex()][plr.entindex()];
		
		if (oldLod[i] != currentLod or (forceUpdateClients[plr.entindex()] && currentLod != LOD_HD)) {
			if (forceUpdateClients[plr.entindex()]) {
			}
			string model = getLodModel(plr, currentLod);
			
			UserInfo info(plr);
			info.model = model;
			info.send(looker);
		}
	}
	
	state.debugPolys = totalPolys;
	state.debugReducedPolys = reducedPolys;
	state.debugVisiblePlayers = pvsPlayers.size();
	state.debugTotalPlayers = totalPlayers;
}

void debug(CBasePlayer@ plr) {
	PlayerState@ state = getPlayerState(plr);
		
	if (state.debug) {
		HUDTextParams params;
		params.effect = 0;
		params.fadeinTime = 0;
		params.fadeoutTime = 0.1;
		params.holdTime = 1.5f;
		
		params.x = -1;
		params.y = 0.99;
		params.channel = 2;
		
		string info = "Visible players: " + state.debugVisiblePlayers + " / " + state.debugTotalPlayers;
		info += "\nVisible polys: " + formatInteger(state.debugPolys);
		if (state.debugPolys != state.debugReducedPolys)
			info += " (reduced to " + formatInteger(state.debugReducedPolys) + ")";
		info += "\nReplaced: ";
		
		int eidx = plr.entindex();
		bool anyReplaced = false;
		
		for (int k = 1; k <= g_Engine.maxClients; k++) {
			int lod = g_replacers[eidx][k];
			if (lod == LOD_HD) {
				continue;
			}
			
			CBasePlayer@ target = g_PlayerFuncs.FindPlayerByIndex(k);
			if (target is null or !target.IsConnected())
				continue;

			Vector lookerPos = plr.pev.origin + plr.pev.view_ofs;
			Vector targetPos = target.pev.origin;
			
			if (target.GetObserver().IsObserver()) {
				CBaseEntity@ ent = null;
				do {
					@ent = g_EntityFuncs.FindEntityByClassname(ent, "deadplayer"); 
					if (ent !is null) {
						CustomKeyvalues@ pCustom = ent.GetCustomKeyvalues();
						CustomKeyvalue ownerKey( pCustom.GetKeyvalue( "$i_hipoly_owner" ) );
						
						if (ownerKey.Exists() && ownerKey.GetInteger() == target.entindex()) {
							targetPos = ent.pev.origin - Vector(0, 0, 30);
						}
					}
				} while (ent !is null);
			}
			
			Color color = lod == LOD_SD ? YELLOW : RED;
			te_beampoints(lookerPos, targetPos, "sprites/laserbeam.spr", 0, 0, 1, 2, 0, color, 32, MSG_ONE_UNRELIABLE, plr.edict());
		
			if (anyReplaced) {
				info += ", ";
			}
			info += getDesiredModel(target) + " " + (lod == LOD_SD ? "(SD)" : "(LD)");
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
	array<bool> forceUpdateClients(33);
	
	// check if any players updated settings which would undo per-client model replacements
	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected())
			continue;
			
		string userInfo = UserInfo(plr).infoString();
		
		if (userInfo != g_cachedUserInfo[plr.entindex()]) {
			g_cachedUserInfo[plr.entindex()] = userInfo;
			forceUpdateClients[i] = true;
		}
	}

	for ( int i = 1; i <= g_Engine.maxClients; i++ ) {		
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected())
			continue;
		
		replace_highpoly_models(plr, forceUpdateClients);	
		debug(plr);
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
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Total polys      : ' + formatInteger(total_polys) + '\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Max visible polys: ' + formatInteger(state.polyLimit) + '\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Safe poly count  : ' + formatInteger(perPlayerLimit) + '    (models below this limit will never be replaced)\n\n');
}

bool doCommand(CBasePlayer@ plr, const CCommand@ args, bool isConsoleCommand=false) {
	PlayerState@ state = getPlayerState(plr);
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if ( args.ArgC() > 0 )
	{
		if (args[0] == ".listpoly") {
			list_model_polys(plr);
		}
		else if (args[0] == ".debugpoly") {
			state.debug = !state.debug;
			g_PlayerFuncs.SayText(plr, 'Poly count debug mode ' + (state.debug ? "ENABLED" : "DISABLED") + '\n');
		}
		else if (args[0] == ".limitpoly") {
			state.polyLimit = Math.max(int(atof(args[1])*1000), defaultLowpolyModelPolys*g_Engine.maxClients);
			state.polyLimit = Math.min(state.polyLimit, 1000000);
			g_PlayerFuncs.SayText(plr, 'Poly limit set to ' + formatInteger(state.polyLimit) + '\n');
		}
		else if (args[0] == ".hipoly") {
			if (args.ArgC() > 1) {
				state.prefersHighPoly = atoi(args[1]) != 0;
				if (state.prefersHighPoly) {
					reset_models(plr);
					g_PlayerFuncs.SayText(plr, "Preference set to high-poly player models (worsens FPS).\n");
				}
				else {
					g_PlayerFuncs.SayText(plr, "Preference set to low-poly player models (improves FPS).\n");
				}
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
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'polygon count is below a limit that you set (WIP).\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nLooking for models with a low poly count? Try here:\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'https://wootguy.github.io/scmodels/\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nCommands:\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".hipoly [0/1]" to toggle model replacement on/off.\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".limitpoly X" to change the polygon limit (X = poly count, in thousands).\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".listpoly" to list each player\'s model and polygon count.\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".debugpoly" to show:\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        - How many player model polys the server thinks you can see.\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        - List of players who are having their models replaced\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        - Lasers showing which models are replaced\n');
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
	{
		pParams.ShouldHide = true;
		return HOOK_HANDLED;
	}
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