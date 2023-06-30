#include "mmlib.h"
#include <set>
#include "main.h"

using namespace std;

uint64_t last_annoying_psa = 0;
uint64_t last_hipoly_psa = 0;
const int annoying_psa_delay = 60 * 30;
const int hipoly_psa_delay = 60 * 30;
const int too_many_polys = 300000; // this is like 10x the recommended poly count for a full server

int g_psa_tick = 0;

const set<string> g_AnnoyingModelList = {
	"apacheshit",
	"big_mom",
	"bmrftruck",
	"bmrftruck2",
	"carshit1",
	"carshit4",
	"carshit5",
	"citroen",
	"corvet",
	"dc_tank",
	"dc_tanks",
	"f_zero_car1",
	"f_modzero_car2",
	"f_zero_car3",
	"f_zero_car4",
	"fdrx7",
	"fockewulftriebflugel",
	"forkliftshit",
	"gaz",
	"gto",
	"hitlerlimo",
	"humvee_be",
	"humvee_desert",
	"humvee_jungle",
	"humvee_sc",
	"mbt",
	"mbts",
	"mbts",
	"friendlygarg",
	"garg",
	"gargantua",
	"gonach",
	"meatwall",
	"onos",
	"owatarobo",
	"owatarobo_s",
	"plantshit2",
	"plantshit3",
	"policecar",
	"policecar2",
	"sil80",
	"sprt_tiefighter",
	"sprt_xwing",
	"tank_mbt",
	"taskforcecar",
	"treeshit",
	"truck",
	"vehicleshit_tigerii",
	"vehicleshit_m1a1_abrams",
	"vehicleshit_submarine",
	"obamium",
	"gigacirno_v2",
	"snarkgarg"
};

void hipoly_models_help_message() {
	double diff = TimeDifference(last_hipoly_psa, getEpochMillis());

	if (diff < hipoly_psa_delay) {
		return;
	}

	if (g_total_polys >= too_many_polys) {
		last_hipoly_psa = getEpochMillis();
		ClientPrintAll(HUD_PRINTTALK, "[Info] Say \".hipoly 0\" to fix low FPS caused by player models.\n");
	}
}

void annoying_model_help_message() {
	double diff = TimeDifference(last_annoying_psa, getEpochMillis());

	if (diff < annoying_psa_delay) {
		return;
	}

	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* plr = INDEXENT(i);

		if (!isValidPlayer(plr)) {
			continue;
		}

		char* info = g_engfuncs.pfnGetInfoKeyBuffer(plr);
		bool isAnnoying = g_AnnoyingModelList.count(toLowerCase(INFOKEY_VALUE(info, "model")));

		if (isAnnoying) {
			last_annoying_psa = getEpochMillis();
			ClientPrintAll(HUD_PRINTTALK, "[Info] Use the .modelswap command to replace annoying player models.\n");
			break;
		}
	}
}

void plugin_help_announcements() {
	g_psa_tick += 1;

	if (g_psa_tick % 2 == 0) {
		annoying_model_help_message();
	}
	else if (g_psa_tick % 2 == 1) {
		hipoly_models_help_message();
	}
}