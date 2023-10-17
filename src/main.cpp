#include "main.h"
#include "GhostReplace.h"
#include "PlayerModelPrecache.h"
#include "PluginHelpAnnouncements.h"
#include <algorithm>
#include <set>

// TODO:
// - special characters in names mess up .listpoly table alignment
// - replace knuckles models with 2d
// - re-apply replacement when changing a userinfo setting
// - constantly update ghost renders instead of adding special logic?
// - show if model is precached in .listpoly
// - ghost disappears in third person
// - include hats in poly count calculation

using namespace std;

// Description of plugin
plugin_info_t Plugin_info = {
	META_INTERFACE_VERSION,	// ifvers
	"Emotes",	// name
	"1.0",	// version
	__DATE__,	// date
	"w00tguy",	// author
	"https://github.com/wootguy/",	// url
	"EMOTES",	// logtag, all caps please
	PT_ANYTIME,	// (when) loadable
	PT_ANYPAUSE,	// (when) unloadable
};

string g_model_list_path = "svencoop/addons/metamod/store/TooManyPolys/models.txt";
string g_alias_list_path = "svencoop/addons/metamod/store/TooManyPolys/aliases.txt";
map<string, ModelInfo> g_model_list;
cvar_t* cvar_default_poly_limit;
map<string,PlayerState> g_player_states;

vector<string> g_cachedUserInfo(33); // used to detect when user info has changed, which undos model replacement
vector<GhostReplace> g_ghostCopys;
set<string> g_precachedModels;
vector<bool> g_wasObserver(33);

int g_total_polys = 0;
int oldObserverStates[33];

// for model refreshing on join
uint32_t g_refresh_idx = 0;
float refreshDelay = 0.5f;

set<string> g_disabled_maps = {
	"sc5x_bonus",
	"hideandseek"
};

PlayerState::PlayerState() {
	polyLimit = cvar_default_poly_limit->value;
}

string PlayerState::getSwapModel(CBasePlayer* target) {
	if (modelSwapAll) {
		return modelSwapAllModel;
	}

	string steamid = toLowerCase(getPlayerUniqueId(target->edict()));
	return modelSwaps[steamid];
}

void MapInit(edict_t* pEdictList, int edictCount, int maxClients) {
	precachePlayerModels();

	for (int i = 0; i < 33; i++) {
		g_wasObserver[i] = false;
		g_cachedUserInfo[i] = "";
	}

	memset(oldObserverStates, 0, sizeof(bool) * 33);

	g_refresh_idx = 0;
}

// Will create a new state if the requested one does not exit
PlayerState& getPlayerState(edict_t* plr) {
	string steamId = getPlayerUniqueId(plr);

	if (g_player_states.find(steamId) == g_player_states.end()) {
		g_player_states[steamId] = PlayerState();
	}

	return g_player_states[steamId];
}

void ClientJoin(edict_t* plr) {
	PlayerState& pstate = getPlayerState(plr);
	pstate.lastJoinTime = gpGlobals->time;
	pstate.lastRefresh = -999;
	pstate.wasLoaded = false;
	pstate.refreshList.resize(0);

	g_Scheduler.SetTimeout(post_join, 0.5f, EHandle(plr));

	RETURN_META(MRES_IGNORED);
}

void PlayerEnteredObserver(edict_t* plr) {
	edict_t* ent = NULL;
	do {
		ent = g_engfuncs.pfnFindEntityByString(ent, "classname", "deadplayer");
		if (isValidFindEnt(ent)) {
			if (!customKeyvalueExists(ent, "$i_hipoly_owner")) {
				writeCustomKeyvalue(ent, "$i_hipoly_owner", ENTINDEX(plr));
				println("Set owner for corpse! %s", STRING(ent->v.classname));
			}
		}
	} while (isValidFindEnt(ent));
}

void loadCrossPluginAfkState() {
	edict_t* afkEnt = FIND_ENTITY_BY_TARGETNAME(NULL, "PlayerStatusPlugin");

	if (!isValidFindEnt(afkEnt)) {
		return;
	}

	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* plr = INDEXENT(i);

		if (!isValidPlayer(plr)) {
			continue;
		}

		PlayerState& state = getPlayerState(plr);

		state.isLoaded = afkEnt->v.iuser4 & (1 << (i & 31));

		if (state.isLoaded && !state.wasLoaded) {
			for (int k = 1; k <= gpGlobals->maxClients; k++) {
				edict_t* p = INDEXENT(k);

				if (!isValidPlayer(p)) {
					continue;
				}

				state.refreshList.push_back(p);
				state.finishedRefresh = false;
			}

			state.wasLoaded = true;
		}
	}
}

// swap all models with something else && back again to fix newly downloaded models appearing as the helmet model
void fix_new_model_dl_bug() {
	int totalChecks = 0;

	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* plr = INDEXENT(i);

		if (!isValidPlayer(plr)) {
			continue;
		}

		PlayerState& state = getPlayerState(plr);
		if (!state.isLoaded) {
			continue;
		}

		// don't refresh too fast in case player lags when loading a huge player model
		if (gpGlobals->time - state.lastRefresh < refreshDelay) {
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
		uint32_t idx = g_refresh_idx % state.refreshList.size();

		CBasePlayer* target = (CBasePlayer*)(state.refreshList[idx].GetEntity());

		if (!target || !target->IsConnected()) {
			state.refreshList.erase(state.refreshList.begin() + idx);
			continue;
		}

		if (target->pev->effects & EF_NODRAW) {
			continue;
		}

		TraceResult tr;
		TRACE_LINE(plr->v.origin, target->pev->origin, ignore_monsters, plr, &tr);

		if (tr.flFraction >= 1.0f) {
			//if (getPlayerUniqueId(plr->edict()) == "STEAM_0:0:5270238")
			//	ClientPrint(plr, HUD_PRINTTALK, "[TMP] Refreshing player model for " + target->pev->netname + " (" + state.refreshList.size() + ")\n");

			refresh_player_model(EHandle(plr), EHandle(target), false);
			g_Scheduler.SetTimeout(refresh_player_model, 0.1f, EHandle(plr), EHandle(target), true);

			state.refreshList.erase(state.refreshList.begin() + idx);
			state.lastRefresh = gpGlobals->time;
		}
	}

	g_refresh_idx++;
}

void refresh_player_model(EHandle h_looker, EHandle h_target, bool isPostSwap) {
	edict_t* looker = h_looker;
	edict_t* target = h_target;

	if (!looker || !target) {
		return;
	}

	UserInfo userInfo = UserInfo(target);

	if (isPostSwap) {
		char* info = g_engfuncs.pfnGetInfoKeyBuffer(target);
		string currentModel = toLowerCase(INFOKEY_VALUE(info, "model"));

		userInfo.model = currentModel;
		userInfo.send(looker);
	}
	else {
		userInfo.model = refreshModel;
		userInfo.send(looker);
	}
}

void post_join(EHandle h_plr) {
	edict_t* plr = h_plr;

	if (!plr) {
		return;
	}

	addPlayerModel(plr);

	for (int i = 0; i < g_ghostCopys.size(); i++) {
		g_ghostCopys[i].setLod(plr, LOD_HD);
	}

	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* p = INDEXENT(i);

		if (!isValidPlayer(p)) {
			continue;
		}

		PlayerState& state = getPlayerState(p);

		bool alreadyExists = false;
		for (int k = 0; k < state.refreshList.size(); k++) {
			CBaseEntity* existEnt = state.refreshList[k];
			if (existEnt && existEnt->entindex() == ENTINDEX(plr)) {
				alreadyExists = true;
				break;
			}
		}

		if (alreadyExists) {
			continue;
		}

		state.refreshList.push_back(EHandle(plr));
		state.finishedRefresh = false;
	}

	do_model_swaps(EHandle());
}

void ClientLeave(edict_t* plr) {
	g_Scheduler.SetTimeout(do_model_swaps, 0.5f, EHandle(plr));
	RETURN_META(MRES_IGNORED);
}

void MapChange(char* s1, char* s2) {
	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* ent = INDEXENT(i);
		if (isValidPlayer(ent))
			addPlayerModel(ent);
	}

	RETURN_META(MRES_IGNORED);
}

void load_model_list() {
	g_model_list.clear();

	FILE* f = fopen(g_model_list_path.c_str(), "r");
	if (!f)
	{
		println("TooManyPolys: Failed to open %s", g_model_list_path.c_str());
		return;
	}

	int modelCount = 0;
	string line;
	while (cgetline(f, line)) {
		if (line.empty()) {
			continue;
		}

		vector<string> parts = splitString(line, "/");
		if (parts.size() < 4) {
			println("Invalid line in model list");
			continue;
		}
		string model_name = parts[0];
		int poly_count = atoi(parts[1].c_str());
		string sd_model = parts[2];
		string ld_model = parts[3];
		//println("LOAD " + model_name + " " + poly_count + " " + replace_model);

		ModelInfo info;
		info.officialName = toLowerCase(model_name);
		info.polys = poly_count;
		info.replacement_sd = sd_model.size() > 0 ? sd_model : defaultLowpolyModel;
		info.replacement_ld = ld_model.size() > 0 ? ld_model : defaultLowpolyModel;

		g_model_list[model_name] = info;
		modelCount++;
	}

	println("TooManyPolys: Loaded %d models from %s", modelCount, g_model_list_path.c_str());

	load_aliases();
}

// redirect old versions && aliases to the latest version of the model
void load_aliases() {
	FILE* f = fopen(g_alias_list_path.c_str(), "r");
	if (!f)
	{
		println("TooManyPolys: Failed to open %s", g_alias_list_path.c_str());
		return;
	}

	int aliasCount = 0;
	string line;
	while (cgetline(f, line)) {
		if (line.empty()) {
			continue;
		}

		vector<string> parts = splitString(line, "/");

		string latest_model_name = parts[0];
		//println("TRY " + latest_model_name);

		if (!g_model_list.count(latest_model_name)) {
			//println("TooManyPolys: Alias info references unknown model: " + line);
			continue;
		}

		ModelInfo latest_info = g_model_list[latest_model_name];

		for (int i = 1; i < parts.size(); i++) {
			if (!g_model_list.count(parts[i])) {
				g_model_list[parts[i]] = latest_info;
				aliasCount++;
			}
		}
	}

	println("TooManyPolys: Duplicated %d ModelInfos from %s", aliasCount, g_alias_list_path.c_str());

	//g_model_list.stats();
}

PlayerModelInfo::PlayerModelInfo() {}

CBaseEntity* PlayerModelInfo::getOwner() {
	if (string(STRING(ent->pev->classname)) == "deadplayer" || string(STRING(ent->pev->classname)) == "monster_ghost") {
		if (owner) {
			return owner;
		}
		else {
			return NULL;
		}
	}
	else {
		return ent; // players own their "player" entity
	}
}

// this entity's model has an SD version
bool PlayerModelInfo::canReplaceSd() {
	if (g_model_list.count(desiredModel)) {
		ModelInfo info = g_model_list[desiredModel];
		return info.hasSdModel();
	}

	return false;
}

// returns the polys for the given LOD on the entity
// the default low poly model is used if no known replacement exists
int PlayerModelInfo::getReplacementPolys(bool standardDefNotLowDef) {
	int multiplier = ent->pev->renderfx == kRenderFxGlowShell ? 2 : 1;
	int replacePolys = defaultLowpolyModelPolys * multiplier;

	if (g_model_list.count(desiredModel)) {
		ModelInfo info = g_model_list[desiredModel];

		string replace_model = standardDefNotLowDef ? info.replacement_sd : info.replacement_ld;
		ModelInfo replaceInfo = g_model_list[replace_model];

		replacePolys = replaceInfo.polys * multiplier;
		if (desiredPolys < replacePolys) {
			println(("Replacement model is higher poly! (" + desiredModel + "(" + to_string(desiredPolys)
				+ ") -> " + replace_model + " (" + to_string(replacePolys) + ")").c_str());
		}
	}

	return replacePolys;
}

bool PlayerModelInfo::hasOwner() {
	return getOwner();
}

vector<PlayerModelInfo> get_visible_players(int& totalPolys, int& totalPlayers) {
	vector<PlayerModelInfo> pvsPlayerInfos;

	totalPolys = 0;

	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* ent = INDEXENT(i);
		CBasePlayer* plr = (CBasePlayer*)GET_PRIVATE(ent);

		if (!isValidPlayer(ent) || !plr || plr->IsObserver()) {
			continue;
		}

		PlayerModelInfo info;
		info.ent = plr;
		info.desiredModel = getDesiredModel(ent);
		info.desiredPolys = getModelPolyCount(plr, info.desiredModel);
		info.replacePolys = info.desiredPolys;
		info.currentReplacement.h_ent = EHandle(plr);
		info.currentReplacement.h_owner = EHandle(plr);
		info.steamid = toLowerCase(getPlayerUniqueId(plr->edict()));
		pvsPlayerInfos.push_back(info);
		totalPolys += info.desiredPolys;
	}

	edict_t* ent = NULL;
	do {
		ent = g_engfuncs.pfnFindEntityByString(ent, "targetname", "plugin_ghost_cam_*");

		if (!isValidFindEnt(ent) || string(STRING(ent->v.model)) == "models/as_ghosts/camera.mdl") {
			continue;
		}

		edict_t* owner = INDEXENT(ent->v.iuser2);
		CBasePlayer* ownerPlr = (CBasePlayer*)GET_PRIVATE(owner);
		CBasePlayer* entBase = (CBasePlayer*)GET_PRIVATE(owner);

		if (!isValidPlayer(owner) || !ownerPlr || !entBase) {
			continue;
		}

		PlayerModelInfo info;
		info.ent = entBase;
		info.owner = ownerPlr;
		info.desiredModel = getDesiredModel(owner);
		info.desiredPolys = getModelPolyCount(ownerPlr, info.desiredModel);
		info.replacePolys = info.desiredPolys;
		info.currentReplacement.h_ent = EHandle(ent);
		info.currentReplacement.h_owner = EHandle(owner);
		info.steamid = toLowerCase(getPlayerUniqueId(owner));
		pvsPlayerInfos.push_back(info);
		totalPolys += info.desiredPolys;
	} while (isValidFindEnt(ent));

	totalPlayers = pvsPlayerInfos.size();

	return pvsPlayerInfos;
}

void reset_models(edict_t* forPlayer) {
	if (forPlayer) {
		for (int i = 1; i <= gpGlobals->maxClients; i++) {
			edict_t* ent = INDEXENT(i);

			if (!isValidPlayer(ent)) {
				continue;
			}

			UserInfo(ent).send(forPlayer);
		}

		for (int i = 0; i < g_ghostCopys.size(); i++) {
			g_ghostCopys[i].setLod(forPlayer, LOD_HD);
		}
	}
}

string getLodModel(edict_t* plr, int lod) {
	string desiredModel = getDesiredModel(plr);

	if (lod == LOD_HD) {
		return desiredModel;
	}

	if (g_model_list.count(desiredModel)) {
		ModelInfo info = g_model_list[desiredModel];
		return lod == LOD_SD ? info.replacement_sd : info.replacement_ld;
	}

	return defaultLowpolyModel;
}

string getDesiredModel(edict_t* plr) {
	char* info = g_engfuncs.pfnGetInfoKeyBuffer(plr);
	return toLowerCase(INFOKEY_VALUE(info, "model"));
}

int getModelPolyCount(CBaseEntity* plr, string model) {
	int multiplier = plr->pev->renderfx == kRenderFxGlowShell ? 2 : 1;

	if (g_model_list.count(model)) {
		return g_model_list[model].polys * multiplier;
	}

	return unknownModelPolys * multiplier; // assume the worst, to encourage adding models to the server
}

// flags models near this player which should be replaced with low poly models
void replace_highpoly_models(edict_t* looker, vector<PlayerModelInfo> playerEnts, int totalPolys) {
	PlayerState& state = getPlayerState(looker);

	if (state.prefersHighPoly || state.modelSwapAll) {
		return; // player doesn't care if there are too many high-poly models on screen
	}

	int maxAllowedPolys = state.polyLimit;
	int reducedPolys = totalPolys;
	int lookeridx = ENTINDEX(looker);

	// reset vars to default because the array is shared with all players
	for (int i = 0; i < playerEnts.size(); i++) {
		playerEnts[i].currentReplacement.lod = LOD_HD;
		playerEnts[i].replacePolys = playerEnts[i].desiredPolys;
		playerEnts[i].canReplace = !state.modelSwaps.count(playerEnts[i].steamid) && playerEnts[i].hasOwner();
	}

	// Pick an LOD for ents in the PVS
	if (playerEnts.size() > 0 && totalPolys > maxAllowedPolys && !state.prefersHighPoly) {

		// SD pass. Do replacements from HD -> SD, but only if the model has an SD replacement.
		// Sort by poly count to replace highest polycount models first
		sort(playerEnts.begin(), playerEnts.end(), [](const PlayerModelInfo& a, const PlayerModelInfo& b) -> bool {
			return a.desiredPolys > b.desiredPolys;
		});

		for (int i = 0; i < playerEnts.size() && reducedPolys > maxAllowedPolys; i++) {
			if (!playerEnts[i].canReplace || !playerEnts[i].canReplaceSd()) {
				continue;
			}

			playerEnts[i].currentReplacement.lod = LOD_SD;
			playerEnts[i].replacePolys = playerEnts[i].getReplacementPolys(true);

			reducedPolys -= playerEnts[i].desiredPolys - playerEnts[i].replacePolys;
		}

		// LD pass. Aggressively set to LD even if the model doesn't have an LD replacement.
		// Sort by polys again now that the SD pass has changed poly counts for each player
		sort(playerEnts.begin(), playerEnts.end(), [](const PlayerModelInfo& a, const PlayerModelInfo& b) -> bool {
			return a.replacePolys > b.replacePolys;
		});

		for (int i = 0; i < playerEnts.size() && reducedPolys > maxAllowedPolys; i++) {
			if (!playerEnts[i].canReplace) {
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
		sort(playerEnts.begin(), playerEnts.end(), [](const PlayerModelInfo& a, const PlayerModelInfo& b) -> bool {
			return a.replacePolys < b.replacePolys;
		});

		for (int i = 0; i < playerEnts.size() && reducedPolys < maxAllowedPolys; i++) {
			if (!playerEnts[i].canReplace || playerEnts[i].currentReplacement.lod != LOD_SD) {
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
	for (int i = 0; i < playerEnts.size(); i++) {
		Replacement& replacement = playerEnts[i].currentReplacement;
		CBaseEntity* replaceEnt = replacement.h_ent;
		CBaseEntity* replaceOwner = replacement.h_owner;

		if (!replaceEnt || !replaceOwner || !playerEnts[i].canReplace) {
			continue;
		}

		if (replaceEnt->IsPlayer()) {
			// player && deadplayer entity models are replaced via UserInfo messages
			string model = getLodModel(replaceOwner->edict(), replacement.lod);
			UserInfo info(replaceOwner->edict());
			info.model = model;
			info.send(looker);
		}
		else {
			// ghost models are replaced by creating new LOD copies that are only visible to certain players
			GhostReplace& ghostCopy = getGhostCopy(replaceEnt, replacement.h_owner);
			ghostCopy.setLod(looker, replacement.lod);
		}
	}
}

// do .modelswap swaps
void do_modelswap_swaps(edict_t* looker, vector<PlayerModelInfo> playerEnts) {
	PlayerState& state = getPlayerState(looker);

	if (!state.modelSwapAll && state.modelSwaps.empty()) {
		return;
	}

	for (int i = 0; i < playerEnts.size(); i++) {
		Replacement& replacement = playerEnts[i].currentReplacement;
		CBaseEntity* replaceEnt = replacement.h_ent;
		CBaseEntity* replaceOwner = replacement.h_owner;

		if (!replaceEnt || !replaceOwner || replaceEnt->entindex() == ENTINDEX(looker)) {
			continue;
		}

		if (replaceEnt->IsPlayer()) {
			// player && deadplayer entity models are replaced via UserInfo messages
			CBasePlayer* plr = (CBasePlayer*)(replaceOwner);

			if (state.modelSwapAll) {
				UserInfo info(plr->edict());
				info.model = state.modelSwapAllModel;
				info.send(looker);
			}
			else if (state.modelSwaps.count(playerEnts[i].steamid)) {
				UserInfo info(plr->edict());
				info.model = state.modelSwaps[playerEnts[i].steamid];
				info.send(looker);
			}
		}
		else {
			// TODO: use a camera model to differentiate between hipoly swaps && personal swaps.
			// ideally the ghost model would be set to the model requested with .modelswap but
			// that would mean creating 32 copies of a ghost entity, for every player. that's
			// not worth the performance hit.
			if (state.modelSwapAll || state.modelSwaps.count(playerEnts[i].steamid)) {
				GhostReplace& ghostCopy = getGhostCopy(replaceEnt, replacement.h_owner);
				ghostCopy.setLod(looker, LOD_LD);
			}
		}
	}
}

void check_if_swaps_needed() {
	bool shouldDoSwaps = false;

	// check if any players updated settings which would undo per-client model replacements
	// this happens in the next loop because there needs to be a delay to ensure models are replaced
	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* ent = INDEXENT(i);
		CBasePlayer* plr = (CBasePlayer*)GET_PRIVATE(ent);

		if (!isValidPlayer(ent) || !plr) {
			continue;
		}

		bool isObserver = plr->IsObserver();
		string userInfo = UserInfo(ent).infoString();

		if (isObserver != g_wasObserver[i] || userInfo != g_cachedUserInfo[plr->entindex()]) {
			shouldDoSwaps = true;
		}

		g_cachedUserInfo[plr->entindex()] = userInfo;
		g_wasObserver[i] = isObserver;
	}

	if (shouldDoSwaps) {
		do_model_swaps(EHandle());
	}
}

void do_model_swaps(EHandle h_plr) {
	if (g_disabled_maps.count(STRING(gpGlobals->mapname))) {
		return;
	}

	CBasePlayer* forPlayer = (CBasePlayer*)(h_plr.GetEntity());

	int totalPolys;
	int totalPlayers;
	vector<PlayerModelInfo> playerEnts = get_visible_players(totalPolys, totalPlayers);
	g_total_polys = totalPolys;

	if (!forPlayer || !forPlayer->IsConnected()) {
		for (int i = 1; i <= gpGlobals->maxClients; i++) {
			CBasePlayer* plr = (CBasePlayer*)GET_PRIVATE(INDEXENT(i));

			if (!plr || !plr->IsConnected())
				continue;

			replace_highpoly_models(plr->edict(), playerEnts, totalPolys);
			do_modelswap_swaps(plr->edict(), playerEnts);
		}
	}
	else {
		replace_highpoly_models(forPlayer->edict(), playerEnts, totalPolys);
		do_modelswap_swaps(forPlayer->edict(), playerEnts);
	}
}

void check_model_names() {
	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		CBasePlayer* plr = (CBasePlayer*)GET_PRIVATE(INDEXENT(i));

		if (!plr || !plr->IsConnected())
			continue;

		char* info = g_engfuncs.pfnGetInfoKeyBuffer(plr->edict());
		string currentModel = toLowerCase(INFOKEY_VALUE(info, "model"));
		ModelInfo latest_info = g_model_list[currentModel];

		if (latest_info.officialName.size() > 0 && latest_info.officialName != currentModel) {
			ClientPrint(plr->edict(), HUD_PRINTTALK, ("Your model was changed to \"" + latest_info.officialName + "\" because \"" + currentModel + "\" is an alias || old version of the same model.\n").c_str());
			ClientPrint(plr->edict(), HUD_PRINTTALK, ("If you see yourself as the helmet model, then wait for the next map. The server will send you " + latest_info.officialName + ".\n").c_str());
			g_engfuncs.pfnSetKeyValue(info, "model", (char*)latest_info.officialName.c_str());
		}
		else if (latest_info.officialName.size() > 23) { // path to model would be longer than 64 characters (max file path length for precaching)
			PlayerState& pstate = getPlayerState(plr->edict());

			// wait a while in case player is still loading
			if ((gpGlobals->time - pstate.lastJoinTime) > 60 && pstate.lastNagModel != latest_info.officialName) {
				pstate.lastNagModel = latest_info.officialName;
				ClientPrint(plr->edict(), HUD_PRINTTALK, ("The name of your model \"" + latest_info.officialName + "\" is too long (23+ characters). The server can't share it with other players.\n").c_str());
			}
		}
	}
}

string formatInteger(int ival) {
	string val = to_string(ival);
	string formatted;
	for (int i = int(val.size()) - 1, k = 0; i >= 0; i--, k++) {
		if (k % 3 == 0 && k != 0) {
			formatted = "," + formatted;
		}
		formatted = val[i] + formatted;
	}
	return formatted;
}

void list_model_polys(edict_t* plr) {
	ClientPrint(plr, HUD_PRINTCONSOLE, "\nPlayer Name              Model Name               Polygon Count        Preference\n");
	ClientPrint(plr, HUD_PRINTCONSOLE, "---------------------------------------------------------------------------------\n");

	vector<ListInfo> mlist;

	for (int i = 1; i <= gpGlobals->maxClients; i++)
	{
		edict_t* lplr = INDEXENT(i);
		if (!isValidPlayer(lplr))
			continue;

		PlayerState& pstate = getPlayerState(lplr);

		string pname = STRING(lplr->v.netname);
		string desiredModel = getDesiredModel(lplr);
		string modelName = desiredModel;

		// client crashes if printing this character
		if (modelName.find("%n") != string::npos) {
			modelName = modelName = "<INVALID>";
		}

		while (pname.size() < 24) {
			pname += " ";
		}
		while (modelName.size() < 24) {
			modelName += " ";
		}
		if (pname.size() > 24) {
			pname = pname.substr(0, 21) + "...";
		}
		if (modelName.size() > 24) {
			modelName = modelName.substr(0, 21) + "...";
		}

		ListInfo info;
		info.playerName = pname;
		info.modelName = modelName;
		info.preference = pstate.prefersHighPoly ? "HD" : "LD";
		info.polys = g_model_list.count(desiredModel) ? int(g_model_list[desiredModel].polys) : -1;

		info.polyString = "??? (not installed)";
		if (info.polys != -1) {
			info.polyString = "" + formatInteger(info.polys);
		}

		while (info.polyString.size() < 24) {
			info.polyString += " ";
		}

		mlist.push_back(info);
	}

	sort(mlist.begin(), mlist.end(), [](const ListInfo& a, const ListInfo& b) -> bool {
		int apolys = a.polys == -1 ? unknownModelPolys : a.polys;
		int bpolys = b.polys == -1 ? unknownModelPolys : b.polys;
		return apolys > bpolys;
	});

	int total_polys = 0;

	for (int i = 0; i < mlist.size(); i++) {
		if (mlist[i].polys != -1) {
			total_polys += mlist[i].polys;
		}
		else {
			total_polys += unknownModelPolys;
		}

		ClientPrint(plr, HUD_PRINTCONSOLE, (mlist[i].playerName + " " + mlist[i].modelName + " "
			+ mlist[i].polyString + " " + mlist[i].preference + "\n").c_str());
	}

	PlayerState& state = getPlayerState(plr);
	int perPlayerLimit = state.polyLimit / gpGlobals->maxClients;
	ClientPrint(plr, HUD_PRINTCONSOLE, "---------------------------------------------------------------------------------\n\n");
	ClientPrint(plr, HUD_PRINTCONSOLE, ("Total polys      = " + formatInteger(total_polys) + "\n").c_str());
	ClientPrint(plr, HUD_PRINTCONSOLE, ("Your poly limit  = " + formatInteger(state.polyLimit) + "\n").c_str());
	ClientPrint(plr, HUD_PRINTCONSOLE, ("Safe model polys = " + formatInteger(perPlayerLimit) + "    (models below this limit will never be replaced)\n\n").c_str());
}

void extSwap() {
	int icaller = atoi(CMD_ARGV(1));
	string target = CMD_ARGV(2);
	string model = CMD_ARGV(3);

	println("[TooManyPolys] extSwap " + to_string(icaller) + " " + target + " " + model);
	edict_t* plr = INDEXENT(icaller);

	if (isValidPlayer(plr)) {
		setModelSwap(plr, toLowerCase(target), model, true);
	}
}

void setModelSwap(edict_t* plr, string targetString, string replacementModel, bool quiet) {
	string nicename;
	string targetid = toLowerCase(targetString);
	bool allPlayers = false;

	PlayerState& state = getPlayerState(plr);

	if (targetid.find("\\") == 0) {
		allPlayers = true;
	}
	else if (targetid.find("steam_0:") == 0) {
		nicename = targetid;
		toUpperCase(nicename);
	}
	else {
		edict_t* target = getPlayerByName(plr, targetid);

		if (!target) {
			return;
		}
		if (ENTINDEX(target) == ENTINDEX(plr)) {
			ClientPrint(plr, HUD_PRINTTALK, "[ModelSwap] Can't modelswap yourself.\n");
			return;
		}

		targetid = getPlayerUniqueId(target);
		targetid = toLowerCase(targetid);
		nicename = target->v.netname;
	}

	string newmodel = defaultLowpolyModel;
	bool shouldUnswap = true;

	if (replacementModel.size() > 0) {
		newmodel = replacementModel;
		shouldUnswap = false;
	}

	if (replacementModel == "?unswap?") {
		shouldUnswap = true;
		state.modelSwaps[targetid] = newmodel; // force an unswap
	}

	if (shouldUnswap && state.modelSwapAll) {
		state.modelSwapAll = false;
		state.modelSwapAllModel = "";
		state.modelSwaps.clear();
		reset_models(plr);
		do_model_swaps(plr);
		if (!quiet)
			ClientPrint(plr, HUD_PRINTTALK, "[ModelSwap] Cancelled model swaps on all players.\n");
	}
	else if (allPlayers) {
		state.modelSwapAll = true;
		state.modelSwapAllModel = newmodel;
		state.modelSwaps.clear();
		do_model_swaps(plr);
		if (!quiet)
			ClientPrint(plr, HUD_PRINTTALK, ("[ModelSwap] Set model \"" + newmodel + "\" on all players.\n").c_str());
	}
	else {
		if (shouldUnswap && state.modelSwaps.count(targetid)) {
			state.modelSwapAll = false;
			state.modelSwapAllModel = "";
			state.modelSwaps.erase(targetid);
			reset_models(plr);
			do_model_swaps(plr);
			if (!quiet)
				ClientPrint(plr, HUD_PRINTTALK, ("[ModelSwap] Cancelled model swap on player \"" + nicename + "\".\n").c_str());
		}
		else {
			state.modelSwapAll = false;
			state.modelSwapAllModel = "";
			state.modelSwaps[targetid] = newmodel;
			do_model_swaps(plr);
			if (!quiet)
				ClientPrint(plr, HUD_PRINTTALK, ("[ModelSwap] Set model \"" + newmodel + "\" on player \"" + nicename + "\".\n").c_str());
		}
	}
}

bool doCommand(edict_t* plr) {
	PlayerState& state = getPlayerState(plr);
	bool isAdmin = AdminLevel(plr) >= ADMIN_YES;

	CommandArgs args = CommandArgs();
	args.loadArgs();

	if (args.ArgC() > 0)
	{
		if (args.ArgV(0) == ".listpoly") {
			list_model_polys(plr);
			return true;
		}
		else if (args.ArgV(0) == ".modelswap" || args.ArgV(0) == ".swapmodel") {
			if (g_disabled_maps.count(STRING(gpGlobals->mapname))) {
				ClientPrint(plr, HUD_PRINTTALK, "Model swaps are disabled on this map.\n");
				return true;
			}

			if (args.ArgC() == 1) {
				ClientPrint(plr, HUD_PRINTTALK, "Force other players to use a model of your choice with this commands:\n");
				ClientPrint(plr, HUD_PRINTTALK, "    .modelswap [player] [model]\n");
				ClientPrint(plr, HUD_PRINTTALK, "[player] can be a Steam ID || incomplete name. Type \\ to target all players.\n");
				ClientPrint(plr, HUD_PRINTTALK, "[model] is the name of a model. Omit this to toggle/cancel a model swap.\n");
				ClientPrint(plr, HUD_PRINTTALK, "Model swaps are visible only to you.\n");
				return true;
			}

			setModelSwap(plr, args.ArgV(1), args.ArgV(2), false);

			return true;
		}
		else if (args.ArgV(0) == ".limitpoly") {
			float arg = Min(atof(args.ArgV(1).c_str()), 1000);
			state.polyLimit = Max(int(arg * 1000), 0);
			if (state.prefersHighPoly) {
				state.prefersHighPoly = false;
			}
			do_model_swaps(plr);
			ClientPrint(plr, HUD_PRINTCENTER, ("Max model polys: " + formatInteger(state.polyLimit) + "\n").c_str());
			return true;
		}
		else if (args.ArgV(0) == ".hipoly") {
			if (args.ArgC() > 1) {
				if (args.ArgV(1) == "toggle") {
					state.prefersHighPoly = !state.prefersHighPoly;
				}
				else {
					state.prefersHighPoly = atoi(args.ArgV(1).c_str()) != 0;
				}
				if (state.prefersHighPoly) {
					reset_models(plr);
					do_model_swaps(plr);
					ClientPrint(plr, HUD_PRINTCENTER, "Max player polys: Unlimited\n");
				}
				else {
					do_model_swaps(plr);
					ClientPrint(plr, HUD_PRINTCENTER, ("Max player polys: " + formatInteger(state.polyLimit) + "\n").c_str());
				}
				return true;
			}
			else {
				if (!args.isConsoleCmd) {
					if (state.prefersHighPoly) {
						ClientPrint(plr, HUD_PRINTTALK, "Preference set to high-poly player models (worsens FPS).\n");
					}
					else {
						ClientPrint(plr, HUD_PRINTTALK, "Preference set to low-poly player models (improves FPS).\n");
					}

					ClientPrint(plr, HUD_PRINTTALK, "Type \".hipoly\" in console for more info\n");
				}
				string desiredModel = getDesiredModel(plr);

				ClientPrint(plr, HUD_PRINTCONSOLE, "------------------------------Too Many Polys Plugin------------------------------\n\n");
				ClientPrint(plr, HUD_PRINTCONSOLE, "This plugin replaces high-poly player models with low-poly versions to improve FPS.\n");

				ClientPrint(plr, HUD_PRINTCONSOLE, "\nModels are replaced in order from most to least polygons, until the total player \n");
				ClientPrint(plr, HUD_PRINTCONSOLE, "polygon count is below a limit that you set.\n");

				ClientPrint(plr, HUD_PRINTCONSOLE, "\nLooking for models with a low poly count? Try here:\n");
				ClientPrint(plr, HUD_PRINTCONSOLE, "https://wootguy.github.io/scmodels/\n");

				ClientPrint(plr, HUD_PRINTCONSOLE, "\nCommands:\n");
				ClientPrint(plr, HUD_PRINTCONSOLE, "    Type \".hipoly [0/1/toggle]\" to toggle model replacement on/off.\n");
				ClientPrint(plr, HUD_PRINTCONSOLE, "    Type \".limitpoly X\" to change the polygon limit (X = poly count, in thousands).\n");
				ClientPrint(plr, HUD_PRINTCONSOLE, "    Type \".listpoly\" to list each player\'s desired model && polygon count.\n");
				ClientPrint(plr, HUD_PRINTCONSOLE, "    Type \".modelswap\" to force other players to use a model of your choice, ignoring polygon count.\n");

				ClientPrint(plr, HUD_PRINTCONSOLE, "\nStatus:\n");
				ClientPrint(plr, HUD_PRINTCONSOLE, ("    Your preference is for " + string(state.prefersHighPoly ? "high-poly" : "low-poly") + " models.\n").c_str());

				if (g_model_list.count(desiredModel)) {
					ModelInfo info = g_model_list[desiredModel];
					ClientPrint(plr, HUD_PRINTCONSOLE, "    Your model's detail levels:\n");
					ClientPrint(plr, HUD_PRINTCONSOLE, ("        HD Model: " + desiredModel + " (" + formatInteger(info.polys) + " polys)\n").c_str());
					ClientPrint(plr, HUD_PRINTCONSOLE, ("        SD Model: " + info.replacement_sd + " (" + formatInteger(g_model_list[info.replacement_sd].polys) + " polys)\n").c_str());
					ClientPrint(plr, HUD_PRINTCONSOLE, ("        LD Model: " + info.replacement_ld + " (" + formatInteger(g_model_list[info.replacement_ld].polys) + " polys)\n").c_str());
				}
				else {
					ClientPrint(plr, HUD_PRINTCONSOLE, ("    Your player model (" + desiredModel + ") is not installed on this server.\n").c_str());
					ClientPrint(plr, HUD_PRINTCONSOLE, "        Because of this, your player model is assumed to have an insanely high\n");
					ClientPrint(plr, HUD_PRINTCONSOLE, ("        poly count (" + formatInteger(unknownModelPolys) + ").\n").c_str());
					ClientPrint(plr, HUD_PRINTCONSOLE, "    Your model\"s detail levels:\n");
					ClientPrint(plr, HUD_PRINTCONSOLE, ("        HD Model: " + desiredModel + " (" + formatInteger(unknownModelPolys) + " polys)\n").c_str());
					ClientPrint(plr, HUD_PRINTCONSOLE, ("        SD Model: " + defaultLowpolyModel + " (" + formatInteger(defaultLowpolyModelPolys) + " polys)\n").c_str());
					ClientPrint(plr, HUD_PRINTCONSOLE, ("        LD Model: " + defaultLowpolyModel + " (" + formatInteger(defaultLowpolyModelPolys) + " polys)\n").c_str());
				}
				int perPlayerLimit = state.polyLimit / gpGlobals->maxClients;
				ClientPrint(plr, HUD_PRINTCONSOLE, ("    Your visible polygon limit is set to "
					+ formatInteger(state.polyLimit) + " (" + formatInteger(perPlayerLimit) + " per player).\n").c_str());

				ClientPrint(plr, HUD_PRINTCONSOLE, "\n---------------------------------------------------------------------------------\n\n");

			}
			return true;
		}
	}
	return false;
}

// called before angelscript hooks
void ClientCommand(edict_t* pEntity) {
	META_RES ret = doCommand(pEntity) ? MRES_SUPERCEDE : MRES_IGNORED;
	RETURN_META(ret);
}

void StartFrame() {
	g_Scheduler.Think();

	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* ent = INDEXENT(i);
		CBasePlayer* plr = (CBasePlayer*)GET_PRIVATE(ent);

		if (!isValidPlayer(ent) || !plr) {
			continue;
		}

		bool newState = plr->IsObserver();

		if (newState && !oldObserverStates[i]) {
			PlayerEnteredObserver(ent);
		}
		/*
		else if (!newState && oldObserverStates[i]) {
			PlayerLeftObserver(ent);
		}
		*/

		oldObserverStates[i] = newState;
	}

	RETURN_META(MRES_IGNORED);
}

void PluginInit() {
	REG_SVR_COMMAND("modelswap_ext", extSwap); // for muting from another plugin
	cvar_default_poly_limit = RegisterCVar("default_poly_limit", "32000", 32000, 0);

	load_model_list();

	g_Scheduler.SetInterval(check_if_swaps_needed, 0.5, -1);
	g_Scheduler.SetInterval(check_model_names, 1.0, -1);
	g_Scheduler.SetInterval(update_ghost_models, 0.05, -1);
	g_Scheduler.SetInterval(loadCrossPluginAfkState, 1.0f, -1);
	g_Scheduler.SetInterval(fix_new_model_dl_bug, 0.2f, -1);
	g_Scheduler.SetInterval(plugin_help_announcements, 1.0f, -1);

	loadPrecachedModels();

	g_dll_hooks.pfnClientCommand = ClientCommand;
	g_dll_hooks.pfnStartFrame = StartFrame;
	g_dll_hooks.pfnClientPutInServer = ClientJoin;
	g_dll_hooks.pfnServerActivate = MapInit;
	g_engine_hooks.pfnChangeLevel = MapChange;
	g_dll_hooks.pfnClientDisconnect = ClientLeave;
}

void PluginExit() {
	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* ent = INDEXENT(i);
		if (isValidPlayer(ent)) {
			UserInfo(ent).broadcast();
		}
	}

	for (int i = 0; i < g_ghostCopys.size(); i++) {
		RemoveEntity(g_ghostCopys[i].ghostSD);
		RemoveEntity(g_ghostCopys[i].ghostLD);
		RemoveEntity(g_ghostCopys[i].ghostRenderSD);
		RemoveEntity(g_ghostCopys[i].ghostRenderLD);
	}
}