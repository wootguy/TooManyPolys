#include "PlayerModelPrecache.h"
#include "mmlib.h"
#include "main.h"
#include <set>

// Code from the PlayerModelPrecacheGeneric plugin.
// TooManyPolys needs to do the same thing for the SD and LD model replacements
using namespace std;

const string g_pmodel_folder_default = "svencoop/models/player/"; // Tailing /
const string g_pmodel_folder_addon = "svencoop_addon/models/player/"; // Tailing /
const string g_pmodel_folder_downloads = "svencoop_downloads/models/player/"; // Tailing /

string g_last_precache_map = "";
set<string> g_ModelList; // list of models to precache
set<string> g_LastModelList; // list of models that were precached on the previous map

const set<string> g_crash_model_list = {
"axis2_s5",
"tomb_rider",
"white_suit",
"axis2_s5_v2",
"tomb_rider_v2",
"white_suit_v2",
"kz_rindo_swc",
"vtuber_filian_sw"
};

void addPlayerModel(edict_t* plr) {
	if (!plr) {
		return;
	}

	char* info = g_engfuncs.pfnGetInfoKeyBuffer(plr);
	string model = toLowerCase(INFOKEY_VALUE(info, "model"));

	if (model.size() && !g_ModelList.count(model)) {
		int res = model.find_first_of("/");

		if (res < 0) {
			g_ModelList.insert(model);
			println("ADD MODEL TO PRECACHE: %s", model.c_str());

			if (g_crash_model_list.count(model)) {
				return;
			}

			if (g_model_list.count(model)) { // also precache the low-poly versions
				ModelInfo info = g_model_list[model];

				g_ModelList.insert(info.replacement_sd);
				g_ModelList.insert(info.replacement_ld);
			}
		}
	}
}

void precachePlayerModels() {
	if (g_last_precache_map == STRING(gpGlobals->mapname)) {
		// player models break fastdl if new ones are precached on a map restart
		g_ModelList = g_LastModelList;
		println("Map was restarted. Scheduled player model precaching cancelled to prevent slowdl bug.");
	}

	println("PRECACHE PLAYTER MODELS NOW");
	g_precachedModels.clear();

	PrecacheModel(defaultLowpolyModelPath);
	PrecacheModel(refreshModelPath);

	for (auto modelname : g_ModelList) {
		string model = modelname + "/" + modelname + ".mdl";
		string tmodel = modelname + "/" + modelname + "t.mdl";
		string pic = modelname + "/" + modelname + ".bmp";

		if (playerModelFileExists(tmodel)) {
			PrecacheGeneric("models/player/" + tmodel);
		}

		if (playerModelFileExists(model)) {
			string path = "models/player/" + model;
			if (path.size() > 64) {
				// 22 char limit for model name
				println("[TooManyPolys] Player model precache failed (65+ chars): " + path + "\n");
				logln("[TooManyPolys] Player model precache failed (65+ chars): " + path + "\n");
			}
			else {
				PrecacheModel("models/player/" + model);
				g_precachedModels.insert(modelname);
				println("OK PRECACHED THIS NOW: %s", model.c_str());
			}
		}

		if (playerModelFileExists(pic)) {
			PrecacheGeneric("models/player/" + pic);
		}
	}

	{
		// share the list of precached models with other plugins
		map<string,string> keys;
		keys["targetname"] = "TooManyPolys";
		int idx = 0;
		for (auto model : g_precachedModels) {
			keys["$s_model" + to_string(idx++)] = model;
			println("ALRIGHT SHARE LOADED MODEL: %s", model.c_str());
		}
		CreateEntity("info_target", keys, true);

		// TODO: update other plugins to use TooManyPolys list
		keys["targetname"] = "PlayerModelPrecacheDyn";
		CreateEntity("info_target", keys, true);
	}

	g_LastModelList = g_ModelList;
	g_last_precache_map = STRING(gpGlobals->mapname);

	g_ModelList.clear();
}

void loadPrecachedModels() {
	g_precachedModels.clear();

	edict_t* precacheEnt = FIND_ENTITY_BY_TARGETNAME(NULL, "TooManyPolys");
	if (isValidFindEnt(precacheEnt)) {
		for (int i = 0; i < 64; i++) {
			string modelName = readCustomKeyvalueString(precacheEnt, "$s_model" + to_string(i));
			if (modelName.length()) {
				g_precachedModels.insert(modelName);
			}
			//println("FOUND PRECACHED: " + modelName);
		}
	}
}

bool playerModelFileExists(string path) {
	return fileExists(g_pmodel_folder_addon + path)
		|| fileExists(g_pmodel_folder_default + path)
		|| fileExists(g_pmodel_folder_downloads + path);
}