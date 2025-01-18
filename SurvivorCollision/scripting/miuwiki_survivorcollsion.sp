#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#define PLUGIN_VERSION "1.0"

public Plugin myinfo =
{
	name = "[L4D2] Survivor Collision",
	author = "Miuwiki",
	description = "Allow survivor collision and stand on other survivor",
	version = PLUGIN_VERSION,
	url = "http://www.miuwiki.site"
}

#define L4D2_MAXPLAYERS 64

/**
 * =========================================================================
 * 
 * =========================================================================
 */

ConVar
	z_avoidteammates;

int
	g_default_z_avoidteamates,
	g_plugin_toggle = 1;

public void OnPluginStart()
{
	RegAdminCmd("sm_allowstandon", Cmd_AllowStandOn, ADMFLAG_ROOT, "Toggle plugin on/off", _, FCVAR_NOTIFY);
	z_avoidteammates = FindConVar("z_avoidteammates");
}

public void OnConfigsExecuted()
{
	g_default_z_avoidteamates = z_avoidteammates.IntValue;

	z_avoidteammates.IntValue = 0;
}

Action Cmd_AllowStandOn(int client, int args)
{
	if( args != 1 )
	{
		ReplyToCommand(client, "usage: !allowstandon <1/0>");
		return Plugin_Handled;
	}

	g_plugin_toggle = GetCmdArgInt(1) == 1 ? 1 : 0;
	z_avoidteammates.IntValue = g_plugin_toggle ? 0 : g_default_z_avoidteamates;

	PrintToChatAll("Admin has change survivor collision to %d", g_plugin_toggle);
	return Plugin_Handled;
}

public void OnClientPutInServer(int client)
{	
	SDKHook(client, SDKHook_PreThink, SDkCallback_MoveTypeCheck);
}

void SDkCallback_MoveTypeCheck(int client)
{
	if( !g_plugin_toggle )
		return;

	if( GetClientTeam(client) != 2 )
		return;

	int groundent = GetEntPropEnt(client, Prop_Send, "m_hGroundEntity");
	if( groundent < 1 || groundent > 31 || !IsClientInGame(groundent) || GetClientTeam(groundent) != 2 )
		return;
	

	// PrintToChat(client, "standing on %N", groundent);
	SetEntPropEnt(client, Prop_Send, "m_hGroundEntity", 0);
}
