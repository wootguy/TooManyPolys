#include "GhostReplace.h"
#include "mmlib.h"
#include "main.h"

using namespace std;

GhostReplace::GhostReplace() {}

GhostReplace::GhostReplace(CBaseEntity* ghostSrc, EHandle h_owner) {
	ghost = ghostSrc;
	this->h_owner = h_owner;

	updateModelInfo();

	if (hasSdModel) {
		ghostSD = createGhostCopy(ghostSrc, modelSD, "_SD");
		ghostRenderSD = createGhostRenderCopy(ghostSrc, "_SD");
	}

	ghostLD = createGhostCopy(ghostSrc, modelLD, "_LD");
	ghostRenderLD = createGhostRenderCopy(ghostSrc, "_LD");

	string originalRenderName = replaceString(string(STRING(ghostSrc->pev->targetname)), "cam_", "render_");
	edict_t* originalRender = FIND_ENTITY_BY_TARGETNAME(NULL, originalRenderName.c_str());

	if (isValidFindEnt(originalRender)) {
		ghostRender = originalRender;
	}
	else {
		println("FAIELD TO FIND ORIGINAL GHOST RENDER");
	}

	for (int i = 1; i <= gpGlobals->maxClients; i++) {
		edict_t* plr = INDEXENT(i);

		if (!isValidPlayer(plr)) {
			continue;
		}

		setLod(plr, LOD_HD);
	}
}

string GhostReplace::getSourceModelName() {
	string modelName = toLowerCase(STRING(ghost.GetEntity()->pev->model));
	return replaceString( modelName.substr(modelName.find_last_of("/") + 1), ".mdl", "");
}

string GhostReplace::formatModelPath(string modelName) {
	return "models/player/" + modelName + "/" + modelName + ".mdl";
}

void GhostReplace::updateModelInfo() {
	currentModel = getSourceModelName();
	ModelInfo modelInfo = g_model_list[currentModel];
	modelSD = formatModelPath(modelInfo.replacement_sd);
	modelLD = formatModelPath(modelInfo.replacement_ld);

	if (!g_precachedModels.count(modelInfo.replacement_sd)) {
		println("NOT PRECACHE " + modelInfo.replacement_sd);
		modelSD = defaultLowpolyModelPath;
	}
	if (!g_precachedModels.count(modelInfo.replacement_ld)) {
		println("NOT PRECACHE " + modelInfo.replacement_ld);
		modelLD = defaultLowpolyModelPath;
	}

	hasSdModel = modelInfo.hasSdModel();
}

CBaseMonster* GhostReplace::createGhostCopy(CBaseEntity* ghostSrc, string model, string suffix) {
	map<string,string> keys;
	keys["origin"] = vecToString(ghostSrc->pev->origin);
	keys["targetname"] = string(STRING(ghostSrc->pev->targetname)) + suffix;
	keys["noise3"] = string(STRING(ghostSrc->pev->noise3));
	keys["rendermode"] = to_string(ghostSrc->pev->rendermode);
	keys["renderamt"] = to_string(ghostSrc->pev->renderamt);
	keys["spawnflags"] = to_string(ghostSrc->pev->spawnflags);
	keys["model"] = model;

	CBaseMonster* ghostCopy = (CBaseMonster*)CreateEntity("monster_ghost", keys, true);
	ghostCopy->pev->solid = ghostSrc->pev->solid;
	ghostCopy->pev->movetype = ghostSrc->pev->movetype;
	ghostCopy->pev->takedamage = ghostSrc->pev->takedamage;
	ghostCopy->pev->angles = ghostSrc->pev->angles;

	ghostCopy->m_Activity = ACT_RELOAD;
	ghostCopy->pev->sequence = ghostSrc->pev->sequence;
	ghostCopy->pev->frame = ghostSrc->pev->frame;
	ghostCopy->ResetSequenceInfo();
	ghostCopy->pev->framerate = ghostSrc->pev->framerate;
	ghostCopy->pev->colormap = ghostSrc->pev->colormap;

	return ghostCopy;
}

CBaseEntity* GhostReplace::createGhostRenderCopy(CBaseEntity* ghostSrc, string suffix) {
	map<string, string> rkeys;
	rkeys["target"] = string(STRING(ghostSrc->pev->targetname)) + suffix;
	rkeys["origin"] = vecToString(ghostSrc->pev->origin);
	rkeys["targetname"] = string(STRING(ghostSrc->pev->targetname)) + "_render" + suffix;
	rkeys["spawnflags"] = to_string(1 | 4 | 8 | 64); // no renderfx + no rendermode + no rendercolor + affect activator
	rkeys["renderamt"] = "0";

	return CreateEntity("env_render_individual", rkeys, true);
}

void GhostReplace::setLod(edict_t* plr, int lod) {
	if (!ghostRender.IsValid() || !ghost.IsValid()) {
		return;
	}

	bool isFirstPerson = ghost.GetEdict()->v.iuser1;

	Use(ghostRender, plr, plr, (lod == LOD_HD && !isFirstPerson) ? USE_OFF : USE_ON);

	bool renderHd = lod == LOD_HD;
	bool renderSd = !isFirstPerson && lod == LOD_SD && ghostRenderSD.IsValid();
	bool renderLd = !isFirstPerson && (lod == LOD_LD || (lod == LOD_SD && !ghostRenderSD.IsValid()));

	int visBit = (1 << (ENTINDEX(plr) & 31));
	if (lod != LOD_HD) {
		// tell the ghosts plugin not to render the ghost for this ghost
		ghost.GetEntity()->pev->iuser3 |= visBit;
	}
	else {
		ghost.GetEntity()->pev->iuser3 &= ~visBit;
	}

	if (ghostRenderSD.IsValid()) {
		Use(ghostRenderSD, plr, plr, renderSd ? USE_OFF : USE_ON);
	}
	Use(ghostRenderLD, plr, plr, renderLd ? USE_OFF : USE_ON);

	lastLod = lod;
}

bool GhostReplace::update() {
	CBaseMonster* source = (CBaseMonster*)(ghost.GetEntity());
	CBaseMonster* camSD = (CBaseMonster*)(ghostSD.GetEntity());
	CBaseMonster* camLD = (CBaseMonster*)(ghostLD.GetEntity());

	if (!source) {
		deleteit();
		return false;
	}

	if (camSD) {
		syncEnt(source, camSD);
	}

	if (camLD) {
		syncEnt(source, camLD);
	}

	if (getSourceModelName() != currentModel) {
		updateModelInfo();
		if (hasSdModel) {
			SET_MODEL(camSD->edict(), modelSD.c_str());
		}
		SET_MODEL(camLD->edict(), modelLD.c_str());
	}

	if (source->pev->iuser1 != wasFirstPerson) {
		setLod(h_owner, lastLod);
	}

	wasFirstPerson = source->pev->iuser1;

	return true;
}

void GhostReplace::syncEnt(CBaseMonster* src, CBaseMonster* dst) {
	dst->pev->velocity = src->pev->velocity;
	dst->pev->avelocity = src->pev->avelocity;

	// frames will be out of sync for differing models, despite that key not caring about frame count.
	// Maybe the framerate key works differently for each model.
	// Not copying frame because it makes the animation really choppy.
	if (dst->pev->framerate != src->pev->framerate || dst->pev->sequence != src->pev->sequence) {
		dst->m_Activity = ACT_RELOAD;
		dst->ResetSequenceInfo();
		dst->pev->framerate = src->pev->framerate;
		dst->pev->frame = src->pev->frame;
		dst->pev->sequence = src->pev->sequence;
	}

	if ((dst->pev->origin - src->pev->origin).Length() > 1) {
		dst->pev->origin = src->pev->origin;
	}
	if (abs(dst->pev->angles.x - src->pev->angles.x) > 1 || abs(dst->pev->angles.y - src->pev->angles.y) > 1) {
		dst->pev->angles = src->pev->angles;
	}
}

void GhostReplace::deleteit() {
	RemoveEntity(ghostSD);
	RemoveEntity(ghostLD);
	RemoveEntity(ghostRenderSD);
	RemoveEntity(ghostRenderLD);
}

bool isGhostVisible(CBaseEntity* ghost, CBaseEntity* looker) {
	// visibility bitfield from the ghosts plugin
	return (ghost->pev->iuser4 & (1 << (looker->entindex() & 31))) != 0;
}

GhostReplace& getGhostCopy(CBaseEntity* ghost, EHandle ghostOwner) {
	for (int i = 0; i < g_ghostCopys.size(); i++) {
		if (g_ghostCopys[i].ghost.IsValid() && ghost->entindex() == ENTINDEX(g_ghostCopys[i].ghost)) {
			return g_ghostCopys[i];
		}
	}

	GhostReplace newReplace = GhostReplace(ghost, ghostOwner);
	g_ghostCopys.push_back(newReplace);

	return g_ghostCopys[g_ghostCopys.size()-1];
}

void update_ghost_models() {
	for (int i = 0; i < g_ghostCopys.size(); i++) {
		if (!g_ghostCopys[i].update()) {
			g_ghostCopys.erase(g_ghostCopys.begin() + i);
			i--;
		}
	}
}
