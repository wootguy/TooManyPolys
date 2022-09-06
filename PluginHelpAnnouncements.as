DateTime last_annoying_psa;
DateTime last_hipoly_psa;
const int annoying_psa_delay = 60*30;
const int hipoly_psa_delay = 60*30;
const int too_many_polys = 300000; // this is like 10x the recommended poly count for a full server

int g_psa_tick = 0;

const array<string> g_AnnoyingModelList = {
	'apacheshit',
	'big_mom',
	'bmrftruck',
	'bmrftruck2',
	'carshit1',
	'carshit4',
	'carshit5',
	'citroen',
	'corvet',
	'dc_tank',
	'dc_tanks',
	'f_zero_car1',
	'f_modzero_car2',
	'f_zero_car3',
	'f_zero_car4',
	'fdrx7',
	'fockewulftriebflugel',
	'forkliftshit',
	'gaz',
	'gto',
	'hitlerlimo',
	'humvee_be',
	'humvee_desert',
	'humvee_jungle',
	'humvee_sc',
	'mbt',
	'mbts',
	'mbts',
	'friendlygarg',
	'garg',
	'gargantua',
	'gonach',
	'meatwall',
	'onos',
	'owatarobo',
	'owatarobo_s',
	'plantshit2',
	'plantshit3',
	'policecar',
	'policecar2',
	'sil80',
	'sprt_tiefighter',
	'sprt_xwing',
	'tank_mbt',
	'taskforcecar',
	'treeshit',
	'truck',
	'vehicleshit_tigerii',
	'vehicleshit_m1a1_abrams',
	'vehicleshit_submarine',
	'obamium',
	'gigacirno_v2',
	'snarkgarg'
};

void plugin_help_announcements() {
	g_psa_tick += 1;
	
	if (g_psa_tick % 2 == 0) {
		annoying_model_help_message();
	} else if (g_psa_tick % 2 == 1) {
		hipoly_models_help_message();
	}
}

void hipoly_models_help_message() {
	int diff = int(TimeDifference(DateTime(), last_hipoly_psa).GetTimeDifference());
	
	if (diff < hipoly_psa_delay) {
		return;
	}
	
	if (g_total_polys >= too_many_polys) {
		last_hipoly_psa = DateTime();
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[Info] Say \".hipoly 0\" to fix low FPS caused by player models.\n" );
	}
}

void annoying_model_help_message() {
	int diff = int(TimeDifference(DateTime(), last_annoying_psa).GetTimeDifference());
	
	if (diff < annoying_psa_delay) {
		return;
	}

	for( int i = 1; i <= g_Engine.maxClients; ++i ) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex( i );

		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		KeyValueBuffer@ pInfos = g_EngineFuncs.GetInfoKeyBuffer( plr.edict() );
		
		bool isAnnoying = g_AnnoyingModelList.find( pInfos.GetValue( "model" ).ToLowercase() ) >= 0;
		
		if (isAnnoying) {
			last_annoying_psa = DateTime();
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[Info] Use the .modelswap command to replace annoying player models.\n" );
			break;
		}
	}
}