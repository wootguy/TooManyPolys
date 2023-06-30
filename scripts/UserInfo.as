// This is used to send player info to a single client instead of globally.
// This way you can swap someone else's player model without them also seeing the swapped model.
class UserInfo {
	int index; // entityindex() - 1

	string cl_lw;
	string cl_lc;
	string bottomcolor;
	string cl_dlmax;
	string cl_updaterate;
	string topcolor;
	string name;
	string sid;
	string rate;
	string cl_hidextra;
	string cl_hideadmin;
	string hud_weaponautoswitch;
	string model;
	
	UserInfo() {}
	
	UserInfo(CBaseEntity@ plr) {
		setInfo(plr);
	}
	
	void setInfo(CBaseEntity@ plr) {
		KeyValueBuffer@ info = g_EngineFuncs.GetInfoKeyBuffer(plr.edict());
		
		cl_lw = info.GetValue("cl_lw");
		cl_lc = info.GetValue("cl_lc");
		bottomcolor = info.GetValue("bottomcolor");
		cl_dlmax = info.GetValue("cl_dlmax");
		cl_updaterate = info.GetValue("cl_updaterate");
		topcolor = info.GetValue("topcolor");
		name = info.GetValue("name");
		sid = info.GetValue("*sid");
		rate = info.GetValue("rate");
		cl_hidextra = info.GetValue("cl_hidextra");
		cl_hideadmin = info.GetValue("cl_hideadmin");
		hud_weaponautoswitch = info.GetValue("hud_weaponautoswitch");
		model = info.GetValue("model");
		
		index = plr.entindex()-1;
	}
	
	string infoString() {
		return "\\cl_lw\\" + cl_lw
			+ "\\cl_lc\\" + cl_lc
			+ "\\bottomcolor\\" + bottomcolor
			+ "\\cl_dlmax\\" + cl_dlmax
			+ "\\cl_updaterate\\" + cl_updaterate
			+ "\\topcolor\\" + topcolor
			+ "\\name\\" + name
			+ "\\*sid\\" + sid
			+ "\\rate\\" + rate
			+ "\\cl_hidextra\\" + cl_hidextra
			+ "\\cl_hideadmin\\" + cl_hideadmin
			+ "\\hud_weaponautoswitch\\" + hud_weaponautoswitch
			+ "\\model\\" + model;
	}
	
	// send info only to one player
	void send(CBasePlayer@ target) {
		// SVC_UPDATEUSERINFO
		NetworkMessage m(MSG_ONE, NetworkMessages::NetworkMessageType(13), target.edict());
			m.WriteByte(index); // player index
			m.WriteLong(0); // client user id (???)
			m.WriteString(infoString());
			
			// CD Key hash (???)
			for (uint i = 0; i < 16; i++) {
				m.WriteByte(0x00);
			}
		m.End();
	}
	
	// send info to everyone
	void broadcast() {
		// SVC_UPDATEUSERINFO
		NetworkMessage m(MSG_ALL, NetworkMessages::NetworkMessageType(13), null);
			m.WriteByte(index); // player index
			m.WriteLong(0); // client user id (???)
			m.WriteString(infoString());
			
			// CD Key hash (???)
			for (uint i = 0; i < 16; i++) {
				m.WriteByte(0x00);
			}
		m.End();
	}
}