#pragma once
#include "mmlib.h"
#include <vector>
#include <string>
#include <set>

using namespace std;

const string defaultLowpolyModel = "player-10up";
const string refreshModel = "ark"; // model swapped to when refreshing player models (should be small for fast loading)
const string defaultLowpolyModelPath = "models/player/" + defaultLowpolyModel + "/" + defaultLowpolyModel + ".mdl";
const string refreshModelPath = "models/player/" + refreshModel + "/" + refreshModel + ".mdl";
const int defaultLowpolyModelPolys = 142;
const int unknownModelPolys = 50000; // assume the worst (better not to risk lowering FPS)

const string moreInfoMessage = "Type '.hipoly' in console for more info.";

struct ModelInfo {
	string officialName;
	uint32 polys = unknownModelPolys;
	string replacement_sd = defaultLowpolyModel; // standard-def replacement, lower poly but still possibly too high
	string replacement_ld = defaultLowpolyModel; // lowest-def replacement, should be a 2D model or the default replacement

	bool hasSdModel() {
		return replacement_sd != replacement_ld && replacement_sd != defaultLowpolyModel;
	}
};

enum LEVEL_OF_DETAIL {
	LOD_HD,
	LOD_SD,
	LOD_LD
};

struct PlayerState {
	bool prefersHighPoly = true; // true if player would rather have horrible FPS than see low poly models
	int polyLimit = 0;
	string lastNagModel = ""; // name of the model that the player was last nagged about
	float lastJoinTime = 0;
	bool isLoaded = false;
	float lastRefresh = 0;
	bool finishedRefresh = false;
	bool wasLoaded = false;

	vector<EHandle> refreshList; // player models to refresh, once they come into view

	bool modelSwapAll = false;
	string modelSwapAllModel = "";
	map<string, string> modelSwaps;
	map<string, string> modelUnswaps;

	PlayerState();

	string getSwapModel(CBasePlayer* target);
};

struct Replacement {
	EHandle h_ent; // entity being replaced
	EHandle h_owner; // player which owns the entity (to know which model is used)
	int lod = LOD_HD; // current level of detail
	string model;
};

struct PlayerModelInfo {
	CBaseEntity* ent;
	CBasePlayer* owner; // if plr is a dead body, then this is the owning player
	string desiredModel;
	int desiredPolys;
	int replacePolys;
	string steamid;
	bool canReplace;

	Replacement currentReplacement;

	PlayerModelInfo();

	CBaseEntity* getOwner();

	// this entity's model has an SD version
	bool canReplaceSd();

	// returns the polys for the given LOD on the entity
	// the default low poly model is used if no known replacement exists
	int getReplacementPolys(bool standardDefNotLowDef);

	bool hasOwner();
};

struct ListInfo {
	string playerName;
	string modelName;
	string preference;
	string polyString;
	int polys; // -1 = unknown
};

extern set<string> g_precachedModels;
extern map<string, ModelInfo> g_model_list;
extern int g_total_polys;

void post_join(EHandle h_plr);
void do_model_swaps(EHandle h_plr);
void refresh_player_model(EHandle h_looker, EHandle h_target, bool isPostSwap);
void load_aliases();
string getDesiredModel(edict_t* plr);
int getModelPolyCount(CBaseEntity* plr, string model);
void setModelSwap(edict_t* plr, string targetString, string replacementModel, bool quiet);