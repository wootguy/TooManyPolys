// Code from the PlayerModelPrecacheGeneric plugin.
// TooManyPolys needs to do the same thing for the SD and LD model replacements

const string g_pmodel_folder_default = "scripts/plugins/store/playermodelfolder_default/"; // Tailing /
const string g_pmodel_folder_addon = "scripts/plugins/store/playermodelfolder_addon/"; // Tailing /
const string g_pmodel_folder_downloads = "scripts/plugins/store/playermodelfolder_downloads/"; // Tailing /

void addPlayerModel(CBasePlayer@ plr) {
	if (plr is null) {
		return;
	}
	
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
}

void precachePlayerModels() {
	g_precachedModels.resize(0);
	
	g_Game.PrecacheModel(defaultLowpolyModelPath);

	for ( uint i = 0; i < g_ModelList.length(); i++ ) {
		string model = g_ModelList[i] + "/" + g_ModelList[i] + ".mdl";
		string tmodel = g_ModelList[i] + "/" + g_ModelList[i] + "t.mdl";
		string pic = g_ModelList[i] + "/" + g_ModelList[i] + ".bmp";

		if ( playerModelFileExists(tmodel) ) {
			g_Game.PrecacheGeneric( "models/player/" + tmodel );
		}

		if ( playerModelFileExists(model) ) {
			g_Game.PrecacheModel( "models/player/" + model );
			g_precachedModels.insertLast(g_ModelList[i]);
		}

		if ( playerModelFileExists(pic) ) {
			g_Game.PrecacheGeneric( "models/player/" + pic );
		}
	}

	// share the list of precached models with other plugins
	dictionary keys;
	keys["targetname"] = "TooManyPolys";
	for ( uint i = 0; i < g_precachedModels.size(); i++ ) {
		keys["$s_model" + i] = g_precachedModels[i];
	}
	g_EntityFuncs.CreateEntity( "info_target", keys, true );

	g_ModelList.resize( 0 );
}

void loadPrecachedModels() {
	g_precachedModels.resize(0);
	
	CBaseEntity@ precacheEnt = g_EntityFuncs.FindEntityByTargetname(null, "TooManyPolys");
	if (precacheEnt !is null) {			
		KeyValueBuffer@ pKeyvalues = g_EngineFuncs.GetInfoKeyBuffer( precacheEnt.edict() );
		CustomKeyvalues@ pCustom = precacheEnt.GetCustomKeyvalues();
		for (int i = 0; i < 64; i++) {
			CustomKeyvalue modelKeyvalue( pCustom.GetKeyvalue( "$s_model" + i ) );
			if (modelKeyvalue.Exists()) {
				string modelName = modelKeyvalue.GetString();
				g_precachedModels.insertLast(modelName);
				println("FOUND PRECACHED: " + modelName);
			}
		}
	}
}

bool playerModelFileExists(string path) {
	File@ pFile = g_FileSystem.OpenFile( g_pmodel_folder_addon + path, OpenFile::READ );
	
	if (pFile !is null && pFile.IsOpen()) {
		pFile.Close();
		return true;
	}
	
	@pFile = g_FileSystem.OpenFile( g_pmodel_folder_default + path, OpenFile::READ );
	
	if (pFile !is null && pFile.IsOpen()) {
		pFile.Close();
		return true;
	}
	
	@pFile = g_FileSystem.OpenFile( g_pmodel_folder_downloads + path, OpenFile::READ );
	
	if (pFile !is null && pFile.IsOpen()) {
		pFile.Close();
		return true;
	}
	
	return false;
}