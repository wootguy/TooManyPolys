#include "HashMap"

// IMPORTANT:
// You need to create a symlink: svencoop_addon/models/player -> svencoop_addon/scripts/plugins/store/playermodelfolder
// also all player model paths should be lowercase, and the player model folder should include default models as well as custom

// TODO:
// - precache secondary models
// - allow manually setting a secondary model
// - performance improvements?

void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

class ModelInfo {
	uint32 polys = defaultLowpolyModelPolys;
	string replacement = defaultLowpolyModel;
}

class PlayerState {
	string desiredModel;
	bool isReduced;
	bool prefersHighPoly; // true if player would rather have horrible FPS than see low poly models
	bool debug; // true if player would rather have horrible FPS than see low poly models
	bool wasEverNotified; // true if the player was ever notified about model replacement
}

string model_list_path = "scripts/plugins/TooManyPolys/models.txt";
const int hashmapBucketCount = 4096;
HashMapModelInfo g_model_list(hashmapBucketCount);
CCVar@ cvar_max_player_polys;
dictionary g_player_states;
array<bool> g_should_player_reduce_polys;
bool g_enabled = true;

const string defaultLowpolyModel = "player-10up";
const int defaultLowpolyModelPolys = 142;
const int unknownModelPolys = 50000; // assume the worst (better not to risk lowering FPS)

const string moreInfoMessage = "Type '.hipoly' in console for more info.";
const string beingReplacedMessage = "Your model is being replaced to improve everyone's FPS. " + moreInfoMessage + "\n";

array<string> g_ModelList; // list of models to precache

void PluginInit()
{
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "asdf" );
	
	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @ClientSay );
	
	//@cvar_max_player_polys = CCVar("max_player_polys", 64000, "max player visble polys", ConCommandFlag::AdminOnly);
	@cvar_max_player_polys = CCVar("max_player_polys", 2000, "max player visble polys", ConCommandFlag::AdminOnly);
	
	g_Hooks.RegisterHook( Hooks::Player::ClientPutInServer, @ClientJoin );
	
	load_model_list();
	
	g_Scheduler.SetInterval("update_models", 0.1, -1);
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
PlayerState@ getPlayerState(CBasePlayer@ plr)
{
	if (plr is null or !plr.IsConnected())
		return null;
		
	string steamId = g_EngineFuncs.GetPlayerAuthId( plr.edict() );
	if (steamId == 'STEAM_ID_LAN' or steamId == 'BOT') {
		steamId = plr.pev.netname;
	}
	
	if ( !g_player_states.exists(steamId) )
	{
		PlayerState state;
		KeyValueBuffer@ p_PlayerInfo = g_EngineFuncs.GetInfoKeyBuffer( plr.edict() );
		state.desiredModel = p_PlayerInfo.GetValue( "model" ).ToLowercase();
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
			
			if (g_model_list.exists(lowermodel)) { // also precache the low-poly version
				g_ModelList.insertLast(g_model_list.get(lowermodel).replacement);
			}
		}
	}

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
		if (parts.size() < 3) {
			println("TooManyPolys: Failed to parse model info: " + line);
			continue;
		}
		parts[0].Trim();
		parts[1].Trim();
		parts[2].Trim();
		string model_name = parts[0];
		int poly_count = atoi(parts[1]);
		string replace_model = parts[2];
		//println("LOAD " + model_name + " " + poly_count + " " + replace_model);
		
		ModelInfo info;
		info.polys = poly_count;
		info.replacement = replace_model;
		
		g_model_list.put(model_name, info);
		modelCount++;
	}
	
	println("TooManyPolys: Loaded " + modelCount + " models from " + model_list_path);
	
	g_model_list.stats();
}

class PlayerModelInfo {
	CBaseEntity@ plr;
	string desiredModel;
	int desiredPolys;
	
	PlayerModelInfo() {}
}

array<PlayerModelInfo> get_visible_players(CBasePlayer@ looker, int&out totalPolys) {	
	Math.MakeVectors( looker.pev.v_angle );
	Vector lookerOrigin = looker.pev.origin - g_Engine.v_forward * 128; // assume chasecam is on
	
	array<PlayerModelInfo> pvsPlayers;
	
	
	//edict_t@ edt = @g_EngineFuncs.EntitiesInPVS(@g_EntityFuncs.Instance(0).edict()); // useless, see HLEnhanced comment
	
	// TODO: this doesn't work on maps with no PVS info or just one area (always assume players are visible then)
	edict_t@ edt = @g_EngineFuncs.EntitiesInPVS(@looker.edict());
	
	
	while (edt !is null)
	{
		CBaseEntity@ ent = g_EntityFuncs.Instance( edt );
		if (ent is null) {
			break;
		}
		@edt = @ent.pev.chain;
		
		CBasePlayer@ plr = cast<CBasePlayer@>(ent);
		
		bool isRendered = (ent.pev.effects & EF_NODRAW) == 0 && (ent.pev.rendermode == 0 || ent.pev.renderamt > 0);
			
		if (plr !is null && plr.IsConnected() && isRendered) {
			
			Vector delta = (plr.pev.origin - lookerOrigin).Normalize();
			
			// check if player is in fov of the looker (can't actually check the fov of a player so this assumes 180 degrees)
			// also assume looker is in first-person perspective. ERP'ers generally use third-person and don't care about lag as much.
			bool isVisible = DotProduct(delta, g_Engine.v_forward) > 0.0;
			
			if (plr.entindex() != looker.entindex() && isVisible) {
				PlayerState@ state = getPlayerState(plr);
				
				PlayerModelInfo info;
				@info.plr = @plr;
				info.desiredModel = state.desiredModel;
				
				int polyCount = 0;
				
				if (g_model_list.exists(state.desiredModel)) {
					polyCount = g_model_list.get(state.desiredModel).polys;
				} else {
					polyCount = unknownModelPolys; // assume the worst, to encourage adding models to the server
					//println("UNKNOWN MODEL: " + state.desiredModel);
				}
				
				info.desiredPolys = polyCount;
				totalPolys += polyCount;
				
				pvsPlayers.insertLast(info);
			}
		}
	}
	
	return pvsPlayers;
}

void reset_models() {
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		if (plr is null or !plr.IsConnected())
			continue;
		
		KeyValueBuffer@ pKeyvalues = g_EngineFuncs.GetInfoKeyBuffer( plr.edict() );
		PlayerState@ state = getPlayerState(plr);
		state.isReduced = false;
		pKeyvalues.SetValue("model", state.desiredModel);
	}
}

void reduce_model_polys() {
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		if (plr is null or !plr.IsConnected())
			continue;
		
		KeyValueBuffer@ pKeyvalues = g_EngineFuncs.GetInfoKeyBuffer( plr.edict() );
		PlayerState@ state = getPlayerState(plr);
		
		// player manually changing their model?
		string currentModel = pKeyvalues.GetValue( "model" ).ToLowercase();
		if (currentModel != state.desiredModel) {
			
			if (state.isReduced) {
				string replaceModel = g_model_list.get(state.desiredModel).replacement;
				
				if (currentModel != replaceModel) {
					g_PlayerFuncs.SayText(plr, beingReplacedMessage);
					pKeyvalues.SetValue("model", replaceModel);
					state.desiredModel = currentModel;
				}
			} else {
				state.desiredModel = currentModel;
			}
		}
		
		if (g_should_player_reduce_polys[i]) {
			if (state.isReduced) {
				//println("Already replaced " + plr.pev.netname);				
				continue;
			}
			
			if (!state.wasEverNotified) {
				state.wasEverNotified = true;
				g_PlayerFuncs.SayText(plr, beingReplacedMessage);
			}
			
			state.isReduced = true;
			state.desiredModel = pKeyvalues.GetValue( "model" ).ToLowercase();
			string replaceModel = g_model_list.get(state.desiredModel).replacement;
			pKeyvalues.SetValue("model", replaceModel);
			
			//println("Replaced model for " + plr.pev.netname + " is " + replaceModel + " DESIRED IS " + state.desiredModel);
		}
		else {
			// restore the desired model
			if (!state.isReduced) {
				//println("Already restored " + plr.pev.netname);
				continue;
			}
			
			if (state.desiredModel.Length() == 0) {
				continue;
			}
			
			println("Restore model " + state.desiredModel + " for " + plr.pev.netname);
			
			pKeyvalues.SetValue("model", state.desiredModel);
			state.isReduced = false;
		}
		
	}
}

// flags models near this player which should be replaced with low poly models
void flag_nearby_highpoly_models(CBasePlayer@ looker) {	
	PlayerState@ state = getPlayerState(looker);
	
	if (state.prefersHighPoly) {
		return; // player doesn't care if there are too many high-poly models on screen
	}

	int totalPolys = 0;
	array<PlayerModelInfo> pvsPlayers = get_visible_players(looker, totalPolys);
	
	int maxAllowedPolys = cvar_max_player_polys.GetInt();
	
	int reducedPolys = totalPolys;
	
	if (pvsPlayers.size() > 0 && totalPolys > maxAllowedPolys) {
		// replace highest polycount models first
		pvsPlayers.sort(function(a,b) { return a.desiredPolys > b.desiredPolys; });
		
		
		for (uint i = 0; i < pvsPlayers.size(); i++) {
			CBaseEntity@ plr = pvsPlayers[i].plr;
			
			g_should_player_reduce_polys[plr.entindex()] = true;
			
			int replacePolys = defaultLowpolyModelPolys;
			if (g_model_list.exists(pvsPlayers[i].desiredModel)) {
				string replace_model = g_model_list.get(pvsPlayers[i].desiredModel).replacement;
				replacePolys = g_model_list.get(replace_model).polys;
				if (pvsPlayers[i].desiredPolys < replacePolys) {
					println("Replacement model is higher poly! (" + pvsPlayers[i].desiredModel + " -> " + replace_model);
				}
			}
			
			reducedPolys -= (pvsPlayers[i].desiredPolys - replacePolys);
			if (reducedPolys < maxAllowedPolys) {
				break;
			}
		}
	}
	
	
	
	if (state.debug) {
		HUDTextParams params;
		params.effect = 0;
		params.fadeinTime = 0;
		params.fadeoutTime = 0.1;
		params.holdTime = 1.5f;
		
		params.x = -1;
		params.y = 0.99;
		params.channel = 2;
		
		string info = "Visible players: " + pvsPlayers.size() + "\nPolys: " + formatInteger(totalPolys);
		if (totalPolys != reducedPolys)
			info += " (reduced to " + formatInteger(reducedPolys) + ")";
		
		g_PlayerFuncs.HudMessage(looker, params, info);
	}
}

void update_models() {
	if (!g_enabled) {
		return;
	}
	
	g_should_player_reduce_polys.resize(0);
	g_should_player_reduce_polys.resize(33);
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		if (plr is null or !plr.IsConnected())
			continue;
		
		flag_nearby_highpoly_models(plr);
	}
	
	reduce_model_polys();
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
	int polys; // -1 = unknown
}

void list_model_polys(CBasePlayer@ plr) {
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nPlayer Name              Model Name               Polygon Count\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '-------------------------------------------------------------------------\n');

	array<ListInfo> mlist;

	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ lplr = g_PlayerFuncs.FindPlayerByIndex(i);
		if (lplr is null or !lplr.IsConnected())
			continue;
		
		PlayerState@ pstate = getPlayerState(lplr);
		
		string pname = lplr.pev.netname;
		string modelName = pstate.desiredModel;
		
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
		info.polys = -1;
		
		if (g_model_list.exists(pstate.desiredModel)) {
			info.polys = g_model_list.get(pstate.desiredModel).polys;
		}
		
		mlist.insertLast(info);
	}
	
	mlist.sort(function(a,b) {
		int apolys = a.polys == -1 ? unknownModelPolys : a.polys;
		int bpolys = b.polys == -1 ? unknownModelPolys : b.polys;
		return apolys > bpolys;
	});
	
	for (uint i = 0; i < mlist.size(); i++) {
		string polyCount = "unknown (not installed)";
		if (mlist[i].polys != -1) {
			polyCount = "" + formatInteger(mlist[i].polys);
		}
		
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, mlist[i].playerName + ' ' + mlist[i].modelName + ' ' + polyCount + '\n');
	}
	
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '-------------------------------------------------------------------------\n\n');
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
		else if (args[0] == ".hipoly") {
			if (args.ArgC() > 1) {
				if (isAdmin && args[1] == 'on') {
					g_enabled = true;
					g_PlayerFuncs.SayTextAll(plr, "High-poly player model replacement is now enabled. " + moreInfoMessage + "\n");
				}
				else if (isAdmin && args[1] == 'off') {
					reset_models();
					g_enabled = false;
					g_PlayerFuncs.SayTextAll(plr, "High-poly player model replacement is now disabled.\n");
				}
				else {
					state.prefersHighPoly = atoi(args[1]) != 0;
					if (state.prefersHighPoly) {
						g_PlayerFuncs.SayText(plr, "Preference set to high-poly player models (worsens FPS).\n");
					}
					else {
						g_PlayerFuncs.SayText(plr, "Preference set to low-poly player models (improves FPS).\n");
					}
				}
				
			} else {
				if (state.prefersHighPoly) {
					g_PlayerFuncs.SayText(plr, "Preference set to high-poly player models (worsens FPS).\n");
				}
				else {
					g_PlayerFuncs.SayText(plr, "Preference set to low-poly player models (improves FPS).\n");
				}
				
				g_PlayerFuncs.SayText(plr, 'Type ".hipoly" in console for more info\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '------------------------------Too Many Polys Plugin------------------------------\n\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'This plugin replaces high-poly player models with low-poly versions to improve FPS.\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nA model is replaced only if other players in the same area can see it and if \n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'at least one of those players is seeing too many player model polygons. Models are\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'replaced in order from most to least polygons, until the visible polygon count is\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'below the limit for any given player.\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nLooking for models with a low poly count? Try here:\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'https://wootguy.github.io/scmodels/\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nCommands:\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".hipoly [0/1]" to set your model poly preference.\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        0 = Prefer low-poly models (improves FPS).\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        1 = Prefer high-poly player models (worsens FPS).\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '            Note: Players in your area without this preference will still cause\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '            models to be replaced.\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".listpoly" to list each player\'s model and polygon count.\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".debugpoly" to show how many player model polys the server thinks you can see.\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nAdmins only:\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Type ".hipoly [on/off]" to enable/disable the plugin\n');
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\nStatus:\n');
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Your preference is for ' + (state.prefersHighPoly ? "high-poly" : "low-poly") +' models.\n');
				
				if (g_model_list.exists(state.desiredModel)) {
					ModelInfo info = g_model_list.get(state.desiredModel);
					int replacePolys = g_model_list.get(info.replacement).polys;
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Your player model (' + state.desiredModel + ') has ' + formatInteger(info.polys) + ' polys.\n');
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    The low-poly version of your model is ' + info.replacement + ' (' + replacePolys + ' polys).\n');
				}
				else {
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Your player model (' + state.desiredModel + ') is not installed on this server.\n');
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        Because of this, your player model is assumed to have an insanely high\n');
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '        poly count (' + formatInteger(unknownModelPolys) +').\n');
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    The low-poly version of your model is ' + defaultLowpolyModel + ' (' + defaultLowpolyModelPolys + ' polys).\n');
				}
				int perPlayerLimit = cvar_max_player_polys.GetInt() / g_Engine.maxClients;
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    The visible polygon limit on this server is ' 
					+ formatInteger(cvar_max_player_polys.GetInt()) + ' (' + formatInteger(perPlayerLimit) + ' per player).\n');
				
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

CClientCommand _hipoly("hipoly", "Too Many Polys commands", @consoleCmd );
CClientCommand _listpoly("listpoly", "Too Many Polys polygon list", @consoleCmd );
CClientCommand _debugpoly("debugpoly", "Too Many Polys polygon list", @consoleCmd );

void consoleCmd( const CCommand@ args ) {
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args, true);
}