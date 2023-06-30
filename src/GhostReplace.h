#include "mmlib.h"

using namespace std;

// entities created by the ghosts plugin don't use player user info.
// So, copies of the ghost that use LD models need to be created and made visible to the players that want them
// this uses 2-3x network usage to keep the ghost copies in sync :<

// Cross-plugin communication done on the ghost entities via these keyvalues:
// iuser2 = player entindex which owns the ghost, set by the ghosts plugin
// iuser3 = bitfield from TooManyPolys which tells the ghost plugin not to render ghosts for the specified players
// iuser4 = bitfield from Ghosts which tells TooManyPolys not to render the ghost for the specified players

struct GhostReplace {
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
	
	EHandle h_owner; // player who owns this ghost
	bool wasFirstPerson;
	int lastLod;

	GhostReplace();

	GhostReplace(CBaseEntity* ghostSrc, EHandle h_owner);

	string getSourceModelName();

	string formatModelPath(string modelName);

	void updateModelInfo();

	CBaseMonster* createGhostCopy(CBaseEntity* ghostSrc, string model, string suffix);

	CBaseEntity* createGhostRenderCopy(CBaseEntity* ghostSrc, string suffix);

	void setLod(edict_t* plr, int lod);

	bool update();

	void syncEnt(CBaseMonster* src, CBaseMonster* dst);

	void deleteit();
};

extern vector<GhostReplace> g_ghostCopys;

bool isGhostVisible(CBaseEntity* ghost, CBaseEntity* looker);

GhostReplace& getGhostCopy(CBaseEntity* ghost, EHandle ghostOwner);

void update_ghost_models();
