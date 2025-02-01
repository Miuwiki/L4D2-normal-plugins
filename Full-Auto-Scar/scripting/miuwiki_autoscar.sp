#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <dhooks>
#include <left4dhooks>

#define PLUGIN_VERSION "1.3"

public Plugin myinfo =
{
	name = "[L4D2] Full Auto Scar",
	author = "Miuwiki",
	description = "Full auto fire mode for Scar",
	version = PLUGIN_VERSION,
	url = "http://www.miuwiki.site"
}

/**
 * =========================================================================
 * Known issue:
 * 1. Use GetEngineTime to checking interupt is not good, 0.05 is too quick that
 * if server lag player won't be able to shot or reload. But i don't know how to 
 * check player be interrupt by other type.
 * 
 * 2. Change full auto mode when reloading or shooting cause problem but i am 
 * too lazy to fix it :)
 * 
 * 3. A simple version of full auto scar is use cl_predict. which doesn't need
 * to consider any otherthing.
 * 
 * 4. Although TE_FireBullet is trigger, no ammo trace when firing and no crater in will.
 * 
 * UPDATE:
 * V1.2:
 * - FIX ERROR SIGNATURE IN WINDOWS (CTerrorPlayer::IsGettingUp)
 * - RECOMMAND USE 60TICK ON SERVER, OR INCREASE THE CVAR 'l4d2_scar_mininterrupt' TO REDUCE THE PROBLEM OF CAN'T FIRE.
 * - CHANGE PREDICT TYPE ONLY WHEN SWITCH WEAPON, NOT IN ONPLAYERRUNCMD.
 * 
 * 
 * V1.1:
 * - FIX RELOAD ANIME PROBLEM
 * - ADD WINDOWS SIGNATURE(NOT CHECK, USE OFFSET INSTEAD).
 * - UPDATE DEFAULT RELOAD TIME.
 * - FIX NO AMMO TRACE AND CRAFT.
 * =========================================================================
 */

#define GAMEDATA "l4d2_auto_desert"

#define SCAR_SHOOT            "weapons/rifle_desert/gunfire/rifle_fire_1.wav"
#define SCAR_SHOOT_INCENDIARY "weapons/rifle_desert/gunfire/rifle_fire_1_incendiary.wav"
#define SCAR_SHOOT_EMPTY      "weapons/clipempty_rifle.wav"

#define SCAR_WORLD_MODEL      "models/w_models/weapons/w_desert_rifle.mdl"

#define DEFAULT_RELOAD_TIME  3.2
#define DEFAULT_ATTACK2_TIME 0.4
#define NOT_IN_RELOAD        0.0

int
	g_scar_precache_index,
	g_Offset_BrustAttackTime;

Handle
	g_SDKCall_FinishReload,
	g_SDKCall_AbortReload,
	g_SDKCall_SeondaryAttack,
	g_SDKCall_PrimaryAttack,
	g_SDKCall_CanAttack,
	g_SDKCall_IsGettingUp;

DynamicHook
	g_DynamicHook_ItemPostFrame;

ConVar
	// cvar_l4d2_scar_mininterrupt,
	cvar_l4d2_scar_cycletime,
	cvar_l4d2_scar_reloadtime;
enum struct GlobalConVar
{
	// float mininterrupt;
	float cycletime;
	float reloadtime;
}
GlobalConVar
	cvar;

enum struct PlayerData
{
	bool  fullautomode;
	bool  needrelease;
	bool  shoveinreload;
	bool  inzoom;

	int   lasttickcount;
	float lastprimaryattacktime;
	float lastsecondaryattacktime;
	float switchendtime;
	float reloadendtime;
	float lastshowinfotime;
}

PlayerData
	player[MAXPLAYERS + 1];

public void OnPluginStart()
{
	LoadGameData();
	// cvar_l4d2_scar_mininterrupt = CreateConVar("l4d2_scar_mininterrupt", "0.05", "min interrupt time. if your server often lag or player can't shoot or reload, add it.", 0, true, 0.03);
	cvar_l4d2_scar_cycletime    = CreateConVar("l4d2_scar_cycletime", "0.11", "scar full auto cycle time. [min 0.03]", 0, true, 0.03);
	cvar_l4d2_scar_reloadtime   = CreateConVar("l4d2_scar_reloadtime", "1.5", "scar full auto reload time. [min 0.5]", 0, true, 0.5);

	// RegConsoleCmd("sm_autoscar", Cmd_AutoScar);
	// AutoExecConfig(true);
}

public void OnMapStart()
{
	g_scar_precache_index = PrecacheModel(SCAR_WORLD_MODEL);

	PrecacheSound(SCAR_SHOOT);
	PrecacheSound(SCAR_SHOOT_INCENDIARY);
	PrecacheSound(SCAR_SHOOT_EMPTY);

	for(int i = 0; i < MAXPLAYERS; i++)
	{
		player[i].lasttickcount           = 0;
		player[i].lastprimaryattacktime   = 0.0;
		player[i].lastsecondaryattacktime = 0.0;
		player[i].switchendtime           = 0.0;
		player[i].reloadendtime           = 0.0;
		player[i].lastshowinfotime        = 0.0;
	}
}

public void OnClientConnected(int client)
{
	if( IsFakeClient(client) )
		return;
	
	player[client].inzoom                  = false;
	player[client].fullautomode            = false;
	player[client].needrelease             = false;
	player[client].shoveinreload           = false;
	player[client].lasttickcount           = 0;
	player[client].lastprimaryattacktime   = 0.0;
	player[client].lastsecondaryattacktime = 0.0;
	player[client].switchendtime           = 0.0;
	player[client].reloadendtime           = 0.0;
	player[client].lastshowinfotime        = 0.0;
}

public void OnConfigsExecuted()
{
	// cvar.mininterrupt = cvar_l4d2_scar_mininterrupt.FloatValue;
	cvar.cycletime    = cvar_l4d2_scar_cycletime.FloatValue;
	cvar.reloadtime   = cvar_l4d2_scar_reloadtime.FloatValue;
}

public void OnClientPutInServer(int client)
{
	if( IsFakeClient(client) )
		return;
	
	SDKHook(client, SDKHook_WeaponSwitchPost, SDKCallback_SwitchDesert);
}

void SDKCallback_SwitchDesert(int client, int weapon)
{
	// static char name[64];
	// GetEntityClassname(weapon, name, sizeof(name));
	// if( strcmp(name, "weapon_rifle_desert") != 0 )
	// {
	// 	SetEntProp(client, Prop_Data, "m_bPredictWeapons", 1);
	// 	return;
	// }
	if( weapon < 1 || !IsValidEntity(weapon) )
		return;
	
	if( GetEntProp(weapon, Prop_Send, "m_iWorldModelIndex") != g_scar_precache_index )
	{
		SetEntProp(client, Prop_Data, "m_bPredictWeapons", 1);
		return;
	}

	// since predict will cause sound problem and no ammo trace, we predict scar whatever which mode it use.
	SetEntProp(client, Prop_Data, "m_bPredictWeapons", 0);

	float currenttime = GetEngineTime();
	if( currenttime - player[client].lastshowinfotime >= 30.0 )
	{
		PrintToChat(client, "\x04[★]\x05SCAR can be full auto. Use \x04mouse3\x05 to change. ");
		player[client].lastshowinfotime = currenttime;
	}
}

// Action Cmd_AutoScar(int client, int args)
// {
// 	if( client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != 2 )
// 		return Plugin_Handled;
	
// 	player[client].fullautomode = !player[client].fullautomode;
// 	if( !player[client].fullautomode )
// 	{
// 		int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
// 		SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", GetGameTime() + 0.1);
// 		SetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack", GetGameTime() + 0.2);
// 		PrintToChat(client, "\x04[★]\x05Your SCAR mode is \x04'Triple Tap'");
// 	}
// 	else
// 	{
// 		PrintToChat(client, "\x04[★]\x05Your SCAR mode is \x04'Full Auto'");
// 	}
// 	return Plugin_Handled;
// }
/**
 * this function trigger when player holding scar
 */
MRESReturn DhookCallback_ItemPostFrame(int pThis)
{
	int client = GetEntPropEnt(pThis, Prop_Send, "m_hOwnerEntity");
	if( client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client) )
		return MRES_Ignored;

	int currenttickcount = GetGameTickCount();
	if( !player[client].fullautomode ) // although we are not in automode, but we have weapon on hand so set the tickcount/
	{
		player[client].lasttickcount = currenttickcount;
		return MRES_Ignored;
	}
		

	Address temp = GetEntityAddress(pThis) + view_as<Address>(g_Offset_BrustAttackTime);
	for(int i = 0; i < 3; i++)
	{
		StoreToAddress(temp + view_as<Address>(4 * i), 0, NumberType_Int32);
	}
	// Address v4 = temp + view_as<Address>(0x17f4);
	// Address v5 = temp + view_as<Address>(0x17f8);
	// Address v6 = temp + view_as<Address>(0x17fc);
	// StoreToAddress(v4, 0, NumberType_Int32);
	// StoreToAddress(v5, 0, NumberType_Int32);
	// StoreToAddress(v6, 0, NumberType_Int32);

	int clip             = GetEntProp(pThis, Prop_Send, "m_iClip1");
	float currenttime    = GetGameTime();

	// PrintToChat(client, "triggering itempostframe, tickcount %d", GetGameTickCount());
	SetEntPropFloat(pThis, Prop_Send, "m_flNextPrimaryAttack", currenttime + 100);
	SetEntPropFloat(pThis, Prop_Send, "m_flNextSecondaryAttack", currenttime + 100);
	// PrintToChat(client, "active desert %f, frametime %f, lastframetime %f, d:%f, cvar:%f", 
	// GetGameTime(), enginetime, player[client].lastenginetime, enginetime - player[client].lastenginetime, cvar.mininterrupt);
	// in switching or interrupt
	if( currenttickcount - player[client].lasttickcount > 1 || SDKCall(g_SDKCall_IsGettingUp, client) )  
	{
		// reset state.
		player[client].needrelease = true;
		player[client].switchendtime = currenttime + 1.1; 
		player[client].reloadendtime = NOT_IN_RELOAD;
		player[client].lasttickcount = currenttickcount;
		return MRES_Ignored;
	}
	player[client].lasttickcount = currenttickcount;
	
	// reload start
	int viewmodel = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
	if( clip == 0 && CanReload(client, clip) && L4D_GetReserveAmmo(client, pThis) > 0 
	&&  currenttime - player[client].lastsecondaryattacktime >= DEFAULT_ATTACK2_TIME ) // not allow in attack2
	{
		// PrintToChat(client, "reload start, time %f", currenttime);
		SDKCall(g_SDKCall_AbortReload, pThis);
		EmitSoundToClient(client, SCAR_SHOOT_EMPTY);
		SetEntProp(viewmodel, Prop_Send, "m_nLayerSequence", 8);
		SetEntPropFloat(viewmodel, Prop_Send, "m_flLayerStartTime", currenttime);
		// SetEntPropFloat(pThis, Prop_Send, "m_flCycle", 0.0);
		SetEntPropFloat(pThis, Prop_Send, "m_flPlaybackRate", DEFAULT_RELOAD_TIME / cvar.reloadtime);
		// L4D2_GetFloatWeaponAttribute("weapon_rifle_desert", L4D2FWA_ReloadDuration);
		player[client].reloadendtime = currenttime + cvar.reloadtime;
		player[client].shoveinreload = false;
		return MRES_Ignored;
	}

	// reload complete
	if( player[client].reloadendtime != NOT_IN_RELOAD && currenttime >= player[client].reloadendtime )
	{
		// PrintToChat(client, "reload complete, time %f", currenttime);
		// int clipsize = L4D2_GetIntWeaponAttribute("weapon_rifle_desert", L4D2IWA_ClipSize);
		// int remainammo = L4D_GetReserveAmmo(client, pThis);
		// if( remainammo >= clipsize )
		// {
		// 	SetEntProp(pThis, Prop_Send, "m_iClip1", clipsize);
		// 	L4D_SetReserveAmmo(client, pThis, remainammo - clipsize);
		// }
		// else
		// {
		// 	SetEntProp(pThis, Prop_Send, "m_iClip1", remainammo);
		// 	L4D_SetReserveAmmo(client, pThis, 0);
		// }
		SDKCall(g_SDKCall_FinishReload, pThis);
		player[client].reloadendtime = NOT_IN_RELOAD;
		if( player[client].shoveinreload )
			SetEntProp(viewmodel, Prop_Send, "m_nLayer", 0);
		// SetEntProp(viewmodel, Prop_Send, "m_nLayerSequence", 1);
		// SetEntProp(viewmodel, Prop_Send, "m_nLayer", 0);
		SetEntPropFloat(viewmodel, Prop_Send, "m_flLayerStartTime", 0.0);
		SetEntPropFloat(pThis, Prop_Send, "m_flPlaybackRate", 1.0);
	}
	
	static int button;
	button = GetClientButtons(client);
	// seondary first
	if( (button & IN_ATTACK2) && CanSecondaryAttack(client) )
	{
		if( currenttime - player[client].lastsecondaryattacktime >= DEFAULT_ATTACK2_TIME )
		{
			// PrintToChat(client, "attacking, time %f", currenttime);
			SetEntPropFloat(pThis, Prop_Send, "m_flNextSecondaryAttack", currenttime);
			SDKCall(g_SDKCall_SeondaryAttack, pThis);
			player[client].lastsecondaryattacktime = currenttime;
			if( player[client].reloadendtime != NOT_IN_RELOAD )
				player[client].shoveinreload = true;
			// if( SDKCall(g_SDKCall_SeondaryAttack, pThis) )
			// 	player[client].lastsecondaryattacktime = currenttime;
			// SetEntPropFloat(pThis, Prop_Send, "m_flNextSecondaryAttack", currenttime + 100.0);
		}
		return MRES_Ignored; // ignore in_attack and in_reload when pushing pushing.
	}

	if( (button & IN_ATTACK) && CanPrimaryAttack(client, clip) )
	{
		if( currenttime - player[client].lastprimaryattacktime >= cvar.cycletime
		&&  currenttime - player[client].lastsecondaryattacktime >= DEFAULT_ATTACK2_TIME ) // not allow in attack2
		{
			// PrintToChat(client, "attacking, time %f", currenttime);
			SetEntPropFloat(pThis, Prop_Send, "m_flNextPrimaryAttack", currenttime);
			SDKCall(g_SDKCall_PrimaryAttack, pThis);
			// SetEntPropFloat(pThis, Prop_Send, "m_flNextPrimaryAttack", currenttime + 100.0);
			player[client].lastprimaryattacktime = currenttime;
			// EmitSoundToClient(client, SCAR_SHOOT);
			// if( L4D2_GetWeaponUpgrades(pThis) & L4D2_WEPUPGFLAG_INCENDIARY )
			// 	EmitSoundToClient(client, SCAR_SHOOT_INCENDIARY);
			// else
			// 	EmitSoundToClient(client, SCAR_SHOOT);
		}
		return MRES_Ignored; // ignore IN_RELOAD when pushing attack button.
	}

	int reserverammo = L4D_GetReserveAmmo(client, pThis);
	if( (button & IN_RELOAD) && CanReload(client, clip) && clip > 0 && reserverammo > 0 )
	{
		L4D_SetReserveAmmo(client, pThis, reserverammo + clip);
		SetEntProp(pThis, Prop_Send, "m_iClip1", 0); // just set to 0 and next frame will reload.
		// SetEntProp(viewmodel, Prop_Send, "m_nLayerSequence", 8);
		// player[client].reloadendtime = currenttime + L4D2_GetFloatWeaponAttribute("weapon_rifle_desert", L4D2FWA_ReloadDuration);
	}
	return MRES_Ignored;
}


bool CanSecondaryAttack(int client)
{
	if( !SDKCall(g_SDKCall_CanAttack, client) )
		return false;
	
	return true;
}

bool CanPrimaryAttack(int client, int clip)
{
	if( clip == 0 || player[client].switchendtime > GetGameTime())
		return false;

	if( player[client].reloadendtime != NOT_IN_RELOAD )
		return false;
		
	if( !SDKCall(g_SDKCall_CanAttack, client) )
		return false;
	
	return true;
}

bool CanReload(int client, int clip)
{
	if( player[client].switchendtime > GetGameTime())
		return false;

	if( player[client].reloadendtime != NOT_IN_RELOAD )
		return false;
		
	if( !SDKCall(g_SDKCall_CanAttack, client) )
		return false;

	if( clip >= L4D2_GetIntWeaponAttribute("weapon_rifle_desert", L4D2IWA_ClipSize))
		return false;
	
	return true;


}

void LoadGameData()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "gamedata/%s.txt", GAMEDATA);
	if( !FileExists(sPath) ) 
		SetFailState("\n==========\nMissing required file: \"%s\".\n==========", sPath);

	GameData hGameData = new GameData(GAMEDATA);
	if(hGameData == null) 
		SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);

	char func[256];
	FormatEx(func, sizeof(func), "CTerrorGun::AbortReload");
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, func);
	if( !(g_SDKCall_AbortReload = EndPrepSDKCall()) )
		SetFailState("failed to start sdkcall \"%s\"", func);
	
	FormatEx(func, sizeof(func), "CTerrorGun::FinishReload");
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, func);
	if( !(g_SDKCall_FinishReload = EndPrepSDKCall()) )
		SetFailState("failed to start sdkcall \"%s\"", func);

	FormatEx(func, sizeof(func), "CRifle_Desert::PrimaryAttack");
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, func);
	if( !(g_SDKCall_PrimaryAttack = EndPrepSDKCall()) )
		SetFailState("failed to start sdkcall \"%s\"", func);
	
	FormatEx(func, sizeof(func), "CTerrorWeapon::SecondaryAttack");
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, func);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	if( !(g_SDKCall_SeondaryAttack = EndPrepSDKCall()) )
		SetFailState("failed to start sdkcall \"%s\"", func);

	FormatEx(func, sizeof(func), "CTerrorPlayer::CanAttack");
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, func);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	if( !(g_SDKCall_CanAttack = EndPrepSDKCall()) )
		SetFailState("failed to start sdkcall \"%s\"", func);
	
	FormatEx(func, sizeof(func), "CTerrorPlayer::IsGettingUp");
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, func);
	if( !(g_SDKCall_IsGettingUp = EndPrepSDKCall()) )
		SetFailState("failed to start sdkcall \"%s\"", func);

	FormatEx(func, sizeof(func), "CRifle_Desert::ItemPostFrame");
	g_DynamicHook_ItemPostFrame = DynamicHook.FromConf(hGameData, func);
	if( !g_DynamicHook_ItemPostFrame )
		SetFailState("Failed to start dynamic hook about \"%s\".", func);

	g_Offset_BrustAttackTime = hGameData.GetOffset("ScarBrustTime");
	delete hGameData;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if( strcmp(classname, "weapon_rifle_desert") == 0 )
	{
		g_DynamicHook_ItemPostFrame.HookEntity(Hook_Post, entity, DhookCallback_ItemPostFrame);
	}
}

// fix that keeping press IN_ATTACK before switch weapon will not fire again after switch complete. 
public Action OnPlayerRunCmd(int client, int &buttons)
{
	if( !player[client].needrelease )
		return Plugin_Continue;
	
	if( !IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != 2 )
		return Plugin_Continue;
	
	buttons &= ~(IN_ATTACK|IN_RELOAD);
	player[client].needrelease = false;

	return Plugin_Changed;
}

public void OnPlayerRunCmdPost(int client, int buttons)
{
	if( buttons & IN_ZOOM )
	{
		if( player[client].inzoom )
			return;
		
		int active_weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if( active_weapon < 1 || !IsValidEntity(active_weapon) )
			return;

		if( GetEntProp(active_weapon, Prop_Send, "m_iWorldModelIndex") != g_scar_precache_index )
			return;

		player[client].inzoom = true;
		player[client].fullautomode = !player[client].fullautomode;
		if( !player[client].fullautomode )
		{
			SetEntPropFloat(active_weapon, Prop_Send, "m_flNextPrimaryAttack", GetGameTime() + 0.1);
			SetEntPropFloat(active_weapon, Prop_Send, "m_flNextSecondaryAttack", GetGameTime() + 0.2);
			PrintToChat(client, "\x04[★]\x05Your SCAR mode is \x04'Triple Tap'");
		}
		else
		{
			PrintToChat(client, "\x04[★]\x05Your SCAR mode is \x04'Full Auto'");
		}
	}
	else
	{
		player[client].inzoom = false;
	}
}
// fix that no craft and ammo trace problem.
// public void OnPlayerRunCmdPre(int client, int buttons)
// {
// 	if(IsFakeClient(client))
// 		return;
	
// 	if( player[client].fullautomode )
// 		SetEntProp(client, Prop_Data, "m_bPredictWeapons", 0);
// 	else
// 		SetEntProp(client, Prop_Data, "m_bPredictWeapons", 1);

// 	// Address state = GetEntityAddress(client) + view_as<Address>(0x70);
// 	// StoreToAddress(state, LoadFromAddress(state, NumberType_Int32) | FL_EDICT_CHANGED, NumberType_Int32);
// 	// SetEntProp(client, Prop_Data, "m_bLagCompensation", 1);
// 	// StoreToAddress(state, LoadFromAddress(state, NumberType_Int32) | FL_EDICT_CHANGED, NumberType_Int32);
// }