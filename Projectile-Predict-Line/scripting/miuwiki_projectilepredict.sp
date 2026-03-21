#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#define PLUGIN_VERSION "1.1"

public Plugin myinfo =
{
	name = "[L4D2] Projectile Predict Line",
	author = "Miuwiki",
	description = "Show projectile predict move line",
	version = PLUGIN_VERSION,
	url = "http://www.miuwiki.site"
}

/**
 * =========================================================================
 * 
 * =========================================================================
 */

#define DEBUG 0

#define GAMEDATA "miuwiki_projectilepredict"

// see CBaseEntity::PhysicsClipVelocity
// see https://github.com/nillerusr/source-engine/blob/29985681a18508e78dc79ad863952f830be237b6/game/shared/cstrike/basecsgrenade_projectile.cpp#L208

#define STOP_EPSILON 		    0.1 
#define SUFACE_ELASTICTY        1.0
#define PLAYER_ELASTICY 		0.3

#define PROJECTILE_DEFAULT_ELASTICITY   0.45  // m_flElasticity
#define PROJECTILE_DEFAULT_THROW_VEL  750.0 // m_vecAbsVelocity length
#define PROJECTILE_DEFAULT_SIZE         1.25  // m_vecmin & m_vecmax

#define MAX_QUADRATICBEAMS      5

#define GRAVATIY_ACCELERATION   5.333313  // WHEN GRAVATY IS 0.400000
#define VELOCITY_PERCENT        0.016666  // EACH VEL TRANSOFRM POS IN NEXT FRAME
#define MAX_TRACE_STEP   		200       // THE MAX STEP OF COLLISION CHECK BEFORE DROP IT

enum struct Quadraticbeam
{
	float startpos[3];
	float startvel[3];
	
	void GetLinePoint(int step, float result[3])
	{
		float percent;
		percent = step * VELOCITY_PERCENT;

		result[0] = this.startpos[0] + percent * this.startvel[0];
		result[1] = this.startpos[1] + percent * this.startvel[1];
		/** wrong.
		 * b = VELOCITY_PERCENT, n = step.
		 * Pn = P + v*b + v1*b + v2*b +... +v(n-1)b
		 * Pn = P + (v-a*0)*b + (v-a*1)*b + (v-a*2)*b +... +(v-a(n-1))b
		 * Pn = P + b(v*n -(a + 2a + 3a + 4a ... +(n-1)a))
		 * Pn = P + b(v*n - ((n-1) / 2) * a*n)
		 * Pn = P + nb(v - a(n-1) / 2)
		 */
		// result[2] = startpos[2] + (step * VELOCITY_PERCENT) * (startvel[2] - GRAVATIY_ACCELERATION * ((step - 1) / 2));
		result[2] = this.startpos[2] + (percent * (this.startvel[2] - (GRAVATIY_ACCELERATION * step) / 2 ));
	}

	void GetLinePointVel(int step, float result[3])
	{
		result = this.startvel;
		result[2] = result[2] - GRAVATIY_ACCELERATION * step;
	}

	void GetControlPoint(int step, float controlpoint[3])
	{
		// float controlpoint[3];
		float point1[3], point2[3], point3[3], point1_vec[3], point2_vec[3], vec3[3], vec4[3];
		this.GetLinePoint(1,         point1);
		this.GetLinePoint(step,      point2);
		this.GetLinePoint(step + 1,  point3);
		MakeVectorFromPoints(this.startpos, point1, point1_vec);
		MakeVectorFromPoints(point2,        point3, point2_vec);
		NormalizeVector(point1_vec, point1_vec);
		NormalizeVector(point2_vec, point2_vec);
		AddVectors(point1_vec, point2_vec, vec4);

		MakeVectorFromPoints(this.startpos, point2, vec3);

		float scale = GetVectorLength(vec3) / GetVectorLength(vec4);
		
		controlpoint[0] = this.startpos[0] + point1_vec[0] * scale;
		controlpoint[1] = this.startpos[1] + point1_vec[1] * scale;
		controlpoint[2] = this.startpos[2] + point1_vec[2] * scale;
	}
}

enum struct GlobalPluginData
{
    bool late;

    Handle SDKCall_SetPosition;
    int precache_laser_id;
    int precache_halo_id;
    int precache_vmodel_pipebomb_id;

    void LoadLate()
    {
        if( !this.late )
            return;
        
        for(int i = 1; i <= MaxClients; i++)
        {
            if( IsClientInGame(i) )
                OnClientPutInServer(i);
        }

        OnMapStart();
    }
}

GlobalPluginData
    plugin;

enum struct GlobalPlayerData
{
	int  quadraticbeam[MAX_QUADRATICBEAMS];
	int  quadraticbeam_ref[MAX_QUADRATICBEAMS];
	bool quadraticbeam_enable[MAX_QUADRATICBEAMS];

	void InitAllBeam()
	{
		for(int i = 0; i < MAX_QUADRATICBEAMS; i++)
		{
			this.quadraticbeam[i]        = CreateQuadraticbeam();
			this.quadraticbeam_ref[i]    = this.quadraticbeam[i] == -1 ? -1 : EntIndexToEntRef(this.quadraticbeam[i]);
			this.quadraticbeam_enable[i] = false;

			// SDKHook(this.quadraticbeam[i], SDKHook_SetTransmit, SDKCallback_QuadraticBeamTransimit);
		}
	}

	void RemoveAllBeam() // base on ref, not entity directly
	{
        char name[64];
        for(int i = 0; i < MAX_QUADRATICBEAMS; i++)
        {
            int check_beam = EntRefToEntIndex(this.quadraticbeam_ref[i]);
            if( check_beam != INVALID_ENT_REFERENCE && IsValidEntity(check_beam) )
            {
                GetEntityClassname(check_beam, name, sizeof(name));
                if( strcmp(name, "env_quadraticbeam") == 0 )
                    RemoveEntity(check_beam);
            }
                
            this.quadraticbeam[i] = -1;
            this.quadraticbeam_ref[i] = -1;
            this.quadraticbeam_enable[i] = false;
        }
	}

	void DisableBeam()
	{
		for(int i = 0; i < MAX_QUADRATICBEAMS; i++)
		{
			this.quadraticbeam_enable[i] = false;
		}
	}

    #if DEBUG
    int templine[MAX_QUADRATICBEAMS];
    #endif
}

GlobalPlayerData
	player[MAXPLAYERS + 1];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    plugin.late = late;
    return APLRes_Success;
}

public void OnPluginStart()
{
    plugin.LoadLate();

    LoadGameData();

    #if DEBUG
        RegConsoleCmd("sm_templine", Cmd_StoreCurrentLine);
        RegConsoleCmd("sm_rmstore", Cmd_RemoveCurrentLine);
    #endif
}

public void OnMapStart()
{
	plugin.precache_vmodel_pipebomb_id  = PrecacheModel("models/v_models/v_pipebomb.mdl");
	plugin.precache_laser_id            = PrecacheModel("materials/sprites/laserbeam.vmt");
	plugin.precache_halo_id             = PrecacheModel("materials/sprites/glow01.vmt");
}

public void OnClientPutInServer(int client)
{
	if( IsFakeClient(client) )
		return;
	
	player[client].InitAllBeam();
}

public void OnClientDisconnect(int client)
{
	player[client].RemoveAllBeam();
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse)
{
	int active_weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	// decal impulse != 201 
	if( !(buttons & (IN_USE))
		|| !IsClientInGame(client) || IsFakeClient(client) 
		|| active_weapon == -1
		|| GetPlayerWeaponSlot(client, 2) != active_weapon
	) 
	{
		player[client].DisableBeam();
		return;
	}

	static float pos[3], ang[3], vec_fwd[3];
	GetClientEyeAngles(client, ang);
	GetClientEyePosition(client, pos);
	GetAngleVectors(ang, vec_fwd, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(vec_fwd, vec_fwd);
	
	ScaleVector(vec_fwd, PROJECTILE_DEFAULT_THROW_VEL);
	// PrintToChatAll("eye pos %f %f %f, \neye vel %f %f %f", pos[0], pos[1], pos[2], vec_fwd[0], vec_fwd[1], vec_fwd[2]);
	// GetEntPropVector(ac)
	player[client].DisableBeam();

    // is pipebome or not GetEntProp(active_weapon, Prop_Send, "m_iViewModelIndex") == plugin.precache_vmodel_pipebomb_id
	DoPredictLine(client, pos, vec_fwd, 0, GetEntProp(active_weapon, Prop_Send, "m_iViewModelIndex") == plugin.precache_vmodel_pipebomb_id);
}

void DoPredictLine(int client, float pos[3], float vel[3], int lineindex, bool pipe)
{
	if( GetVectorLength(vel, true) < 900 ) // 30 * 30
		return;

	if( lineindex >= MAX_QUADRATICBEAMS ) // the max beam count.
		return;
	
	player[client].quadraticbeam_enable[lineindex] = true;

	int step;
	Quadraticbeam beam;
	beam.startpos = pos;
	beam.startvel = vel;

	float point1[3], point2[3], hit[3], point1_vel[3], reflectionvel[3], planenormal[3], controlpoint[3];
	Handle trace;
	
	do
	{
		beam.GetLinePoint(step,     point1);
		beam.GetLinePoint(step + 1, point2);
		beam.GetLinePointVel(step, point1_vel);
		trace = TR_TraceHullFilterEx(point1, 
									 point2, 
									 {-PROJECTILE_DEFAULT_SIZE, -PROJECTILE_DEFAULT_SIZE, -PROJECTILE_DEFAULT_SIZE},
									 {PROJECTILE_DEFAULT_SIZE, PROJECTILE_DEFAULT_SIZE, PROJECTILE_DEFAULT_SIZE},
									 MASK_SOLID,
									 TraceFilter_Thrower,
									 client);
		int ent = TR_GetEntityIndex(trace);
		if( TR_DidHit(trace) && (ent < 1 || ent > 31) ) // player seem doesn't block projectile to move.
		{
			TR_GetEndPosition(hit, trace);
			TR_GetPlaneNormal(trace, planenormal);
			// SDKCall(g_SDKCall_PhysicsClipVelocity, startvel, planenormal, vel_reflec, 2.0); // SDKCall need a entity, i copy the actually code that the func use in the next.
			GetReflection(point1_vel, planenormal, reflectionvel, 2.0);                        // We can't actually get the vel in hit position, just use the point1_vel as approximate.
			// float elasticity = ent > 0 && ent < 31 ? PLAYER_ELASTICY : SUFACE_ELASTICTY;    // We don't trace player collision so don't need to consider this.

			ScaleVector(reflectionvel, minmax(PROJECTILE_DEFAULT_ELASTICITY * SUFACE_ELASTICTY, 0.0, 0.9));
			reflectionvel[2] = reflectionvel[2] > 150.0 ? 150.0 : reflectionvel[2];
			if( !pipe )
				ScaleVector(reflectionvel, 0.4);

			if( planenormal[2] > 0.7 ) // FLOOR
			{
				if( GetVectorLength(reflectionvel, true) < 900 || !pipe ) // (30 * 30) or not pipe
				{
                    // next predict will be return immedately in this recusion function. since vel is too slow.
					reflectionvel = {0.0, 0.0, 0.0};
				}
				// Does not change the entities velocity at all | https://github.com/nillerusr/source-engine/blob/master/game/server/physics_main.cpp#L1214
				else 
				{
					// Vector vecDelta = GetBaseVelocity() - vecAbsVelocity;	
					// Vector vecBaseDir = GetBaseVelocity();
					// VectorNormalize( vecBaseDir );
					// float flScale = vecDelta.Dot( vecBaseDir );
					// VectorScale( vecAbsVelocity, ( 1.0f - trace.fraction ) * gpGlobals->frametime, vecVelocity ); 
					// VectorMA( vecVelocity, ( 1.0f - trace.fraction ) * gpGlobals->frametime, GetBaseVelocity() * flScale, vecVelocity );
					// PhysicsPushEntity( vecVelocity, &trace );
					
					// looks like it consider the floor which is moving.
					// we ignore that so the base velocity always {0.0,0.0,0.0}
					// float vec_delta[3], vec_base[3], vec_reflection_copy[3], result[3];
					// GetEntPropVector(client, Prop_Send, "m_vecBaseVelocity", vec_base);
					// SubtractVectors(vec_base, reflectionvel, vec_delta);
					// NormalizeVector(vec_base, vec_base);
					// float scale = GetVectorDotProduct(vec_delta, vec_base);
					// vec_reflection_copy = reflectionvel;
					// ScaleVector(vec_base, scale);
					// ScaleVector(vec_reflection_copy, (1.0 - TR_GetFraction(trace)) * GetGameFrameTime());
					// // PrintToChat(client, "reflectionvel %f %f %f", reflectionvel[0],reflectionvel[1],reflectionvel[2]);
					// VectorMA(vec_reflection_copy, (1.0 - TR_GetFraction(trace) ) * GetGameFrameTime(), vec_base, result);
					// // PrintToChat(client, "result %f %f %f", result[0],result[1],result[2]);
					// // // PhysicsPushEntity( vecVelocity, &trace );
					// PrintToChat(client, "line %d hit vel %f %f %f", lineindex, reflectionvel[0],reflectionvel[1],reflectionvel[2]);
				}
			}
			else if( GetVectorLength(reflectionvel, true) < 900 )
			{
                // next predict will be return immedately in this recusion function. since vel is too slow.
				reflectionvel = {0.0, 0.0, 0.0};
			}
			
			beam.GetControlPoint(step, controlpoint);
			DrawLine(client, beam.startpos, hit, controlpoint, lineindex);
			DoPredictLine(client, hit, reflectionvel, lineindex + 1, pipe); // next line.
			delete trace;
			break;
		}

		step++;
		delete trace;
	}
	while( step < MAX_TRACE_STEP ); // if too far and no collision, ignore that.
	
	if( step == MAX_TRACE_STEP ) // if overcome the step with no collision, only draw this line.
	{
		beam.GetLinePoint(MAX_TRACE_STEP, point2);
		beam.GetControlPoint(MAX_TRACE_STEP, controlpoint);
		DrawLine(client, beam.startpos, point2, controlpoint, lineindex);
	}
}

bool TraceFilter_Thrower(int entity, int contentsMask, int thrower)
{
	if( entity == thrower )
		return false;
	
	return true;
}

void DrawLine(int client, float startpos[3], float endpos[3], float controlpoint[3], int lineindex)
{
	int beam;
	if( player[client].quadraticbeam[lineindex] == -1 
	 || player[client].quadraticbeam_ref[lineindex] == -1 
	 || EntRefToEntIndex(player[client].quadraticbeam_ref[lineindex]) != player[client].quadraticbeam[lineindex] )
	{
		beam = CreateQuadraticbeam();

		if( beam == -1 )
		{
			LogMessage("showing quadraticbeam for %N with line index %d failed!", client, lineindex);
			return;
		}
		else
		{
			player[client].quadraticbeam[lineindex] = beam;
			player[client].quadraticbeam_ref[lineindex] = EntIndexToEntRef(beam);
		}
	}
	else
	{
		beam = player[client].quadraticbeam[lineindex];
	}

	SetEntPropVector(beam, Prop_Send, "m_targetPosition", endpos);
	SetEntPropVector(beam, Prop_Send, "m_controlPosition", controlpoint);
	SDKCall(plugin.SDKCall_SetPosition, beam, startpos);
}

Action SDKCallback_QuadraticBeamTransimit(int entity, int client)
{
	for(int i = 0; i < MAX_QUADRATICBEAMS; i++)
	{
		if( entity == player[client].quadraticbeam[i] && player[client].quadraticbeam_enable[i] )
			return Plugin_Continue;
	}

	return Plugin_Stop;
}

int CreateQuadraticbeam()
{
	int beam = CreateEntityByName("env_quadraticbeam");
	if( beam == -1 )
		return -1;

	SetEntityModel(beam, "materials/sprites/laserbeam.vmt");
	// SetEntPropVector(line, Prop_Send, "m_targetPosition", endpos);
	// SetEntPropVector(line, Prop_Send, "m_controlPosition", controlpoint);
	SetEntPropFloat(beam, Prop_Send, "m_scrollRate", 0.0);
	SetEntPropFloat(beam, Prop_Send, "m_flWidth", 2.0);
	
	// AcceptEntityInput(line, "Color 0 0 0");
	DispatchSpawn(beam);
	TeleportEntity(beam, {0.0,0.0,0.0});

	SDKHook(beam, SDKHook_SetTransmit, SDKCallback_QuadraticBeamTransimit);
	return beam;
}

void LoadGameData()
{
	GameData hGameData = new GameData(GAMEDATA);
	if(hGameData == null) 
		SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);
	
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "CBaseEntity::SetLocalOrigin");
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	if( !(plugin.SDKCall_SetPosition = EndPrepSDKCall()) )
		SetFailState("failed to load signature");

	delete hGameData;
}



/**
 * https://github.com/mastercomfig/tf2-patches/blob/adce75185fe5822309f356424ea449dee029e2d8/src/game/shared/physics_main_shared.cpp#L1339
 */
stock int GetReflection(float vel_in[3], float normal[3], float vel_out[3], float overbounce)
{
	float	backoff;
	float	change;
	float   angle;
	int		i, blocked;
	
	blocked = 0;

	angle = normal[ 2 ];

	if ( angle > 0 )
	{
		blocked |= 1;		// floor
	}
	if ( !angle )
	{
		blocked |= 2;		// step
	}
	
	backoff = GetVectorDotProduct(vel_in, normal) * overbounce;

	for ( i=0 ; i<3 ; i++ )
	{
		change = normal[i]*backoff;
		vel_out[i] = vel_in[i] - change;
		if (vel_out[i] > -STOP_EPSILON && vel_out[i] < STOP_EPSILON)
		{
			vel_out[i] = 0.0;
		}
	}
	
	return blocked;
}

stock void VectorMA(const float start[3], float scale, const float direction[3], float dest[3])
{
	dest[0] = start[0] + direction[0] * scale;
	dest[1] = start[1] + direction[1] * scale;
	dest[2] = start[2] + direction[2] * scale;
}

stock float minmax(float a, float min, float max)
{
	static float t;
	t = a < min ? min : a;
	return t > max ? max : t;
}

#if DEBUG
Action Cmd_StoreCurrentLine(int client, int args)
{
	float endpos[3], controlpoint[3], startpos[3], lastendpos[3];
	GetClientEyePosition(client, startpos);
	for(int i = 0; i < sizeof(player[].templine); i++)
	{
		if( player[client].templine[i] < 31 )
		{
			player[client].templine[i] = CreateQuadraticbeam();
		}

		if( player[client].templine[i] == -1 )
			continue;
		
		SDKUnhook(player[client].templine[i], SDKHook_SetTransmit, SDKCallback_QuadraticBeamTransimit);
		GetEntPropVector(player[client].quadraticbeam[i], Prop_Send, "m_targetPosition", endpos);
		GetEntPropVector(player[client].quadraticbeam[i], Prop_Send, "m_controlPosition", controlpoint);
		SetEntPropVector(player[client].templine[i], Prop_Send, "m_targetPosition", endpos);
		SetEntPropVector(player[client].templine[i], Prop_Send, "m_controlPosition", controlpoint);
		if( i == 0 )
			SDKCall(plugin.SDKCall_SetPosition, player[client].templine[i], startpos);
		else
			SDKCall(plugin.SDKCall_SetPosition, player[client].templine[i], lastendpos);
		
		lastendpos = endpos;
	}

	return Plugin_Handled;
}

Action Cmd_RemoveCurrentLine(int client, int args)
{
	for(int i = 0; i < MAX_QUADRATICBEAMS; i++)
	{
		if( player[client].templine[i] < 31 || !IsValidEntity(player[client].templine[i]) )
			continue;

		RemoveEntity(player[client].templine[i]);
	}

	return Plugin_Handled;
}

void SDKCallback_MolotovProjectileSpawn(int entity)
{
	if( entity > 31 && IsValidEntity(entity) )
	{
		RequestFrame(NextFrame_GetVel, entity);
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	#if DEBUG
		if( strcmp(classname, "pipe_bomb_projectile") == 0 )
		{
			SDKHook(entity, SDKHook_SpawnPost, SDKCallback_MolotovProjectileSpawn);
		}
	#endif 
}

void NextFrame_GetVel(int entity)
{
	TE_SetupBeamFollow(entity, plugin.precache_laser_id, plugin.precache_halo_id, 100.0, 1.0, 3.0, 1, {70, 50, 150, 255});
	TE_SendToAll();
}
#endif