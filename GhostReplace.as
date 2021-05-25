// entities created by the ghosts plugin don't use player user info.
// So, copies of the ghost that use LD models need to be created and made visible to the players that want them
// this uses 2-3x network usage to keep the ghost copies in sync :<

// Cross-plugin communication done on the ghost entities via these keyvalues:
// iuser2 = player entindex which owns the ghost, set by the ghosts plugin
// iuser3 = bitfield from TooManyPolys which tells the ghost plugin not to render ghosts for the specified players
// iuser4 = bitfield from Ghosts which tells TooManyPolys not to render the ghost for the specified players

class GhostReplace {
	EHandle ghost;
	EHandle ghostSD;
	EHandle ghostLD;
	
	// env_render_individual ents to control visibility of the ghost ents
	EHandle ghostRender; // same ent that the ghosts plugin created
	EHandle ghostRenderSD;
	EHandle ghostRenderLD;
	
	string currentModel;
	string modelSD;
	string modelLD;
	bool hasSdModel;
	
	GhostReplace() {}
	
	GhostReplace(CBaseEntity@ ghostSrc) {
		ghost = ghostSrc;
		
		updateModelInfo();
		
		if (hasSdModel) {			
			ghostSD = createGhostCopy(ghostSrc, modelSD, "_SD");
			ghostRenderSD = createGhostRenderCopy(ghostSrc, "_SD");
		}
		
		ghostLD = createGhostCopy(ghostSrc, modelLD, "_LD");
		ghostRenderLD = createGhostRenderCopy(ghostSrc, "_LD");
		
		string originalRenderName = string(ghostSrc.pev.targetname).Replace("cam_", "render_");
		CBaseEntity@ originalRender = g_EntityFuncs.FindEntityByTargetname(null, originalRenderName);
		
		if (originalRender !is null) {
			ghostRender = originalRender;
		} else {
			println("FAIELD TO FIND ORIGINAL GHOST RENDER");
		}
		
		for ( int i = 1; i <= g_Engine.maxClients; i++ ) {
			CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
			
			if (plr is null or !plr.IsConnected())
				continue;
				
			setLod(plr, LOD_HD);
		}
	}
	
	string getSourceModelName() {
		string modelName = string(ghost.GetEntity().pev.model).ToLowercase();
		return modelName.SubString(modelName.FindLastOf("/")+1).Replace(".mdl", "");
	}
	
	string formatModelPath(string modelName) {
		return "models/player/" + modelName + "/" + modelName + ".mdl";
	}
	
	void updateModelInfo() {
		currentModel = getSourceModelName();
		ModelInfo modelInfo = g_model_list.get(currentModel);
		modelSD = formatModelPath(modelInfo.replacement_sd);
		modelLD = formatModelPath(modelInfo.replacement_ld);
		
		if (g_precachedModels.find(modelInfo.replacement_sd) == -1) {
			println("NOT PRECACHE " + modelInfo.replacement_sd);
			modelSD = defaultLowpolyModelPath;
		}
		if (g_precachedModels.find(modelInfo.replacement_ld) == -1) {
			println("NOT PRECACHE " + modelInfo.replacement_ld);
			modelLD = defaultLowpolyModelPath;
		}
		
		hasSdModel = modelInfo.hasSdModel();
	}
	
	CBaseMonster@ createGhostCopy(CBaseEntity@ ghostSrc, string model, string suffix) {
		dictionary keys;
		keys["origin"] = ghostSrc.pev.origin.ToString();
		keys["targetname"] = string(ghostSrc.pev.targetname) + suffix;
		keys["rendermode"] = "" + ghostSrc.pev.rendermode;
		keys["renderamt"] = "" + ghostSrc.pev.renderamt;
		keys["spawnflags"] = "" + ghostSrc.pev.spawnflags;
		keys["model"] = model;
		
		CBaseMonster@ ghostCopy = cast<CBaseMonster@>(g_EntityFuncs.CreateEntity("cycler", keys, true));
		ghostCopy.pev.solid = ghostSrc.pev.solid;
		ghostCopy.pev.movetype =  ghostSrc.pev.movetype;
		ghostCopy.pev.takedamage = ghostSrc.pev.takedamage;
		ghostCopy.pev.angles = ghostSrc.pev.angles;
		
		ghostCopy.m_Activity = ACT_RELOAD;
		ghostCopy.pev.sequence = ghostSrc.pev.sequence;
		ghostCopy.pev.frame = ghostSrc.pev.frame;
		ghostCopy.ResetSequenceInfo();
		ghostCopy.pev.framerate = ghostSrc.pev.framerate;
		ghostCopy.pev.colormap = ghostSrc.pev.colormap;
		
		return ghostCopy;
	}
	
	CBaseEntity@ createGhostRenderCopy(CBaseEntity@ ghostSrc, string suffix) {
		dictionary rkeys;
		rkeys["target"] = string(ghostSrc.pev.targetname) + suffix;
		rkeys["origin"] = ghostSrc.pev.origin.ToString();
		rkeys["targetname"] = string(ghostSrc.pev.targetname) + "_render" + suffix;
		rkeys["spawnflags"] = "" + (1 | 4 | 8 | 64); // no renderfx + no rendermode + no rendercolor + affect activator
		rkeys["renderamt"] = "0";
		
		return g_EntityFuncs.CreateEntity("env_render_individual", rkeys, true);
	}
	
	void setLod(CBasePlayer@ plr, int lod) {
		ghostRender.GetEntity().Use(plr, plr, lod == LOD_HD ? USE_OFF : USE_ON);
		
		int visBit = (1 << (plr.entindex() & 31));
		if (lod != LOD_HD) {
			// tell the ghosts plugin not to render the ghost for this ghost
			ghost.GetEntity().pev.iuser3 |= visBit;
		} else {
			ghost.GetEntity().pev.iuser3 &= ~visBit;
		}
		
		if (ghostRenderSD.IsValid()) {
			ghostRenderSD.GetEntity().Use(plr, plr, lod == LOD_SD ? USE_OFF : USE_ON);
			ghostRenderLD.GetEntity().Use(plr, plr, lod == LOD_LD ? USE_OFF : USE_ON);
		} else {
			ghostRenderLD.GetEntity().Use(plr, plr, lod == LOD_SD or lod == LOD_LD ? USE_OFF : USE_ON);
		}
	}
	
	bool update() {
		CBaseMonster@ source = cast<CBaseMonster@>(ghost.GetEntity());
		CBaseMonster@ camSD = cast<CBaseMonster@>(ghostSD.GetEntity());
		CBaseMonster@ camLD = cast<CBaseMonster@>(ghostLD.GetEntity());
		
		if (source is null) {
			delete();
			return false;
		}
		
		if (camSD !is null) {
			syncEnt(source, camSD);
		}
		
		if (camLD !is null) {
			syncEnt(source, camLD);
		}
		
		if (getSourceModelName() != currentModel) {
			updateModelInfo();
			if (hasSdModel) {
				g_EntityFuncs.SetModel(camSD, modelSD);
			}
			g_EntityFuncs.SetModel(camLD, modelLD);
		}
		
		return true;
	}
	
	void syncEnt(CBaseMonster@ src, CBaseMonster@ dst) {
		dst.pev.velocity = src.pev.velocity;
		dst.pev.avelocity = src.pev.avelocity;
		
		// frames will be out of sync for differing models, despite that key not caring about frame count.
		// Maybe the framerate key works differently for each model.
		// Not copying frame because it makes the animation really choppy.
		if (dst.pev.framerate != src.pev.framerate or dst.pev.sequence != src.pev.sequence) {
			dst.m_Activity = ACT_RELOAD;
			dst.ResetSequenceInfo();
			dst.pev.framerate = src.pev.framerate;
			dst.pev.frame = src.pev.frame;
			dst.pev.sequence = src.pev.sequence;
		}
		
		if ((dst.pev.origin - src.pev.origin).Length() > 1) {
			dst.pev.origin = src.pev.origin;
		}
		if (abs(dst.pev.angles.x - src.pev.angles.x) > 1 || abs(dst.pev.angles.y - src.pev.angles.y) > 1) {
			dst.pev.origin = src.pev.origin;
		}
	}
	
	void delete() {
		g_EntityFuncs.Remove(ghostSD);
		g_EntityFuncs.Remove(ghostLD);
		g_EntityFuncs.Remove(ghostRenderSD);
		g_EntityFuncs.Remove(ghostRenderLD);
	}
}

bool isGhostVisible(CBaseEntity@ ghost, CBaseEntity@ looker) {
	// visibility bitfield from the ghosts plugin
	return ghost.pev.iuser4 & (1 << (looker.entindex() & 31)) != 0;
}

GhostReplace@ getGhostCopy(CBaseEntity@ ghost) {
	for (uint i = 0; i < g_ghostCopys.size(); i++) {
		if (ghost.entindex() == g_ghostCopys[i].ghost.GetEntity().entindex()) {
			return g_ghostCopys[i];
		}
	}
	
	GhostReplace newReplace = GhostReplace(ghost);
	g_ghostCopys.insertLast(newReplace);
	
	return newReplace;
}

void update_ghost_models() {
	for (uint i = 0; i < g_ghostCopys.size(); i++) {
		if (!g_ghostCopys[i].update()) {
			g_ghostCopys.removeAt(i);
			i--;
		}
	}
}
