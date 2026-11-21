#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <multicolors>

#undef REQUIRE_EXTENSIONS
#include <clientprefs>
#define REQUIRE_EXTENSIONS

#define PLUGIN_VERSION "1.3.4-srcdslab"

enum struct SavedScore
{
	int frags;
	int deaths;
	int cash;
	int time;
}

ConVar g_cvEnabled;
ConVar g_cvTrackingTime;
ConVar g_cvForever;
ConVar g_cvAllowReset;
ConVar g_cvCash;
ConVar g_cvSpecCash;
ConVar g_cvLan;
ConVar g_cvStartMoney;

// Saved scores, keyed by Steam2 ID. Kept in memory: they only need to outlive a reconnect
// (or, in forever mode, a map change), so no database and no query on the game thread.
StringMap g_smScores;

bool g_bJustConnected[MAXPLAYERS + 1] = { true, ... };
bool g_bMenuItemCreated;
bool g_bNextRoundNewGame;
float g_fRestartGameTime;

// Forever mode: last known score of each player, given back after a game restart
int g_iTrackedFrags[MAXPLAYERS + 1];
int g_iTrackedDeaths[MAXPLAYERS + 1];
int g_iTrackedCash[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name = "Save Scores",
	author = "exvel, .Rushaway",
	description = "Restores kills, deaths and optionally cash when a player reconnects during the same map",
	version = PLUGIN_VERSION,
	url = "https://github.com/srcdslab/sm-plugin-SaveScores"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_CSS)
	{
		strcopy(error, err_max, "This plugin only supports Counter-Strike: Source");
		return APLRes_Failure;
	}

	MarkNativeAsOptional("SetCookieMenuItem");
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("savescores.phrases");

	CreateConVar("sm_save_scores_version", PLUGIN_VERSION, "Save Scores version", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	g_cvEnabled = CreateConVar("sm_save_scores", "1", "Enable save scores, 0 = off/1 = on", _, true, 0.0, true, 1.0);
	g_cvTrackingTime = CreateConVar("sm_save_scores_tracking_time", "20", "Amount of time in minutes to store a player score for, 0 = for the duration of the map", _, true, 0.0, true, 60.0);
	g_cvForever = CreateConVar("sm_save_scores_forever", "0", "Keep saved scores across map changes and game restarts until an admin uses sm_save_scores_reset (lost on server restart or plugin reload), 0 = off/1 = on", _, true, 0.0, true, 1.0);
	g_cvAllowReset = CreateConVar("sm_save_scores_allow_reset", "1", "Allow players to reset their score (resetscore console command and !settings menu item), 0 = off/1 = on", _, true, 0.0, true, 1.0);
	g_cvCash = CreateConVar("sm_save_scores_css_cash", "1", "Also restore the cash of reconnecting players, 0 = off/1 = on", _, true, 0.0, true, 1.0);
	g_cvSpecCash = CreateConVar("sm_save_scores_css_spec_cash", "1", "Save the cash of players moving to spectators and restore it when they join a team again, 0 = off/1 = on", _, true, 0.0, true, 1.0);

	g_cvLan = FindConVar("sv_lan");
	g_cvStartMoney = FindConVar("mp_startmoney");

	ConVar cvRestartGame = FindConVar("mp_restartgame");
	if (cvRestartGame != null)
		cvRestartGame.AddChangeHook(OnRestartGameChanged);

	HookEvent("player_team", Event_PlayerTeam);
	HookEvent("player_disconnect", Event_PlayerDisconnect);
	HookEvent("round_start", Event_RoundStart);
	HookEvent("round_end", Event_RoundEnd);

	RegConsoleCmd("resetscore", Command_ResetScore, "Resets your kills and deaths back to 0");
	RegAdminCmd("sm_save_scores_reset", Command_Clear, ADMFLAG_GENERIC, "Resets all saved scores");

	AutoExecConfig(true, "plugin.savescores");

	g_smScores = new StringMap();

	// Late load: players already in game are not "just connected"
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
			g_bJustConnected[client] = false;
	}

	// Forever mode tracks every player's score each second
	CreateTimer(1.0, Timer_TrackScores, _, TIMER_REPEAT);
}

public void OnConfigsExecuted()
{
	// Client settings menu item for resetting scores
	if (!g_bMenuItemCreated && g_cvEnabled.BoolValue && g_cvAllowReset.BoolValue
		&& GetFeatureStatus(FeatureType_Native, "SetCookieMenuItem") == FeatureStatus_Available)
	{
		SetCookieMenuItem(CookieMenu_ResetScore, 0, "Reset Score");
		g_bMenuItemCreated = true;
	}
}

public void OnMapStart()
{
	g_bNextRoundNewGame = false;
	g_fRestartGameTime = 0.0;

	if (!g_cvForever.BoolValue)
		ClearScores();
}

public void OnMapEnd()
{
	// Forever mode: save everyone so they get their score back on the next map
	if (!IsActive() || !g_cvForever.BoolValue)
		return;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client))
			SaveClientScore(client);
	}
}

public void OnClientConnected(int client)
{
	g_bJustConnected[client] = true;
	g_iTrackedFrags[client] = 0;
	g_iTrackedDeaths[client] = 0;
	g_iTrackedCash[client] = 0;
}

bool IsActive()
{
	return g_cvEnabled.BoolValue && !g_cvLan.BoolValue;
}

void ClearScores()
{
	delete g_smScores;
	g_smScores = new StringMap();
}

// mp_restartgame: the game restarts after the given amount of seconds, and the round that
// starts then is a new game. The game sets the cvar back to 0 right away: ignore that.
void OnRestartGameChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	int iSeconds = StringToInt(newValue);
	if (iSeconds > 0)
		g_fRestartGameTime = GetGameTime() + float(iSeconds);
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (!IsActive() || !g_cvForever.BoolValue)
		return;

	char sMessage[32];
	event.GetString("message", sMessage, sizeof(sMessage));

	if (StrEqual(sMessage, "#Game_Commencing") || StrEqual(sMessage, "#Round_Draw"))
		g_bNextRoundNewGame = true;
}

// A new game resets every score: forget the saved ones, or in forever mode give them back
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (g_fRestartGameTime > 0.0 && GetGameTime() >= g_fRestartGameTime - 0.1)
	{
		g_fRestartGameTime = 0.0;
		g_bNextRoundNewGame = true;
	}

	if (!g_bNextRoundNewGame)
		return;

	g_bNextRoundNewGame = false;

	if (!g_cvForever.BoolValue)
	{
		ClearScores();
		return;
	}

	if (!IsActive())
		return;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client) && !g_bJustConnected[client])
		{
			SetClientScore(client, g_iTrackedFrags[client], g_iTrackedDeaths[client]);
			SetClientCash(client, g_iTrackedCash[client]);
		}
	}
}

public Action Timer_TrackScores(Handle timer)
{
	if (!IsActive() || !g_cvForever.BoolValue)
		return Plugin_Continue;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client) && IsClientAuthorized(client) && !g_bJustConnected[client])
		{
			g_iTrackedFrags[client] = GetClientFrags(client);
			g_iTrackedDeaths[client] = GetClientDeaths(client);
			g_iTrackedCash[client] = GetClientCash(client);
		}
	}

	return Plugin_Continue;
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (!IsActive() || event.GetBool("disconnect"))
		return;

	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);

	if (!client || !IsClientInGame(client) || IsFakeClient(client))
		return;

	int iTeam = event.GetInt("team");

	if (!g_bJustConnected[client])
	{
		if (!g_cvSpecCash.BoolValue)
			return;

		// Moved to spectators after playing: save the score (only the cash is given back)
		if (iTeam == 1)
			SaveClientScore(client);
		// Back from spectators: give the cash back
		else if (iTeam > 1 && event.GetInt("oldteam") < 2)
			RequestFrame(Frame_RestoreScore, PackRestore(userid, true));

		return;
	}

	// First team join since connecting
	if (iTeam != 1)
	{
		g_bJustConnected[client] = false;
		RequestFrame(Frame_RestoreScore, PackRestore(userid, false));
	}
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (!client || !IsClientInGame(client) || IsFakeClient(client))
		return;

	if (IsActive())
		SaveClientScore(client);
}

// Restore one frame after the team change, once the game is done with the player
int PackRestore(int userid, bool bOnlyCash)
{
	return (userid << 1) | view_as<int>(bOnlyCash);
}

void Frame_RestoreScore(int data)
{
	int client = GetClientOfUserId(data >> 1);
	if (client && IsClientInGame(client) && IsActive())
		RestoreClientScore(client, view_as<bool>(data & 1));
}

void SaveClientScore(int client)
{
	char sAuth[32];
	if (!GetClientAuthId(client, AuthId_Steam2, sAuth, sizeof(sAuth)))
		return;

	SavedScore score;
	score.frags = GetClientFrags(client);
	score.deaths = GetClientDeaths(client);
	score.cash = GetClientCash(client);
	score.time = GetTime();

	// Nothing worth saving: also drop any older entry, so a reset score (from this plugin or
	// another one such as ResetScore) is never undone on the next reconnect
	bool bCashMatters = g_cvCash.BoolValue || g_cvSpecCash.BoolValue;
	if (score.frags == 0 && score.deaths == 0 && (!bCashMatters || score.cash == g_cvStartMoney.IntValue))
	{
		g_smScores.Remove(sAuth);
		return;
	}

	g_smScores.SetArray(sAuth, score, sizeof(score));
}

void RestoreClientScore(int client, bool bOnlyCash)
{
	char sAuth[32];
	if (!GetClientAuthId(client, AuthId_Steam2, sAuth, sizeof(sAuth)))
		return;

	SavedScore score;
	if (!g_smScores.GetArray(sAuth, score, sizeof(score)))
		return;

	bool bForever = g_cvForever.BoolValue;
	int iTrackingTime = g_cvTrackingTime.IntValue;

	// Saved too long ago
	if (!bOnlyCash && !bForever && iTrackingTime != 0 && GetTime() - score.time > iTrackingTime * 60)
	{
		g_smScores.Remove(sAuth);
		return;
	}

	if (!bOnlyCash && (score.frags != 0 || score.deaths != 0))
	{
		SetClientScore(client, score.frags, score.deaths);
		CPrintToChat(client, "{green}%t", "Score restored");
	}

	if (g_cvCash.BoolValue)
	{
		SetClientCash(client, score.cash);
		CPrintToChat(client, "{green}%t", "Cash restored", score.cash);
	}

	if (!bForever)
		g_smScores.Remove(sAuth);
}

void ResetClientScore(int client)
{
	SetClientScore(client, 0, 0);

	char sAuth[32];
	if (GetClientAuthId(client, AuthId_Steam2, sAuth, sizeof(sAuth)))
		g_smScores.Remove(sAuth);
}

public Action Command_ResetScore(int client, int args)
{
	if (!g_cvEnabled.BoolValue || !g_cvAllowReset.BoolValue)
		return Plugin_Handled;

	if (!client)
	{
		CReplyToCommand(client, "%t", "Players only");
		return Plugin_Handled;
	}

	ResetClientScore(client);
	CReplyToCommand(client, "{green}%t", "You have just reset your score");
	return Plugin_Handled;
}

public void CookieMenu_ResetScore(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
{
	if (action == CookieMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlen, "%T", "Reset Score", client);
		return;
	}

	if (!g_cvEnabled.BoolValue || !g_cvAllowReset.BoolValue)
		return;

	ResetClientScore(client);
	CPrintToChat(client, "{green}%t", "You have just reset your score");
}

public Action Command_Clear(int client, int args)
{
	if (!g_cvEnabled.BoolValue)
	{
		CReplyToCommand(client, "%t", "Save Scores disabled");
		return Plugin_Handled;
	}

	ClearScores();

	int iStartMoney = g_cvStartMoney.IntValue;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			SetClientScore(i, 0, 0);
			SetClientCash(i, iStartMoney);
		}
	}

	CReplyToCommand(client, "%t", "All scores reset");
	return Plugin_Handled;
}

void SetClientScore(int client, int frags, int deaths)
{
	SetEntProp(client, Prop_Data, "m_iFrags", frags);
	SetEntProp(client, Prop_Data, "m_iDeaths", deaths);
}

int GetClientCash(int client)
{
	return GetEntProp(client, Prop_Send, "m_iAccount");
}

void SetClientCash(int client, int cash)
{
	SetEntProp(client, Prop_Send, "m_iAccount", cash);
}
