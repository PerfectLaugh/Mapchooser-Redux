#pragma semicolon 1
#pragma newdecls required

#include <mapchooser_redux>
#include <nextmap>
#include <cstrike>
#include <smutils>

// options
#undef REQUIRE_PLUGIN
#include <store>
#include <shop>

Handle g_NominationsResetForward;
Handle g_MapVoteStartedForward;
Handle g_MapVoteEndForward;
Handle g_MapDataLoadedForward;

Handle g_tVote;
Handle g_tRetry;
Handle g_tWarning;

Handle g_hVoteMenu;

ArrayList g_aMapList;
ArrayList g_aNominateList;
ArrayList g_aNominateOwners;
ArrayList g_aOldMapList;
ArrayList g_aNextMapList;

int g_iExtends;
int g_iMapFileSerial = -1;
int g_iNominateCount;
int g_iRunoffCount;
bool g_bHasVoteStarted;
bool g_bWaitingForVote;
bool g_bMapVoteCompleted;
bool g_bChangeMapInProgress;
bool g_bChangeMapAtRoundEnd;
bool g_bWarningInProgress;
bool g_bBlockedSlots;

bool g_pStore;
bool g_pShop;

enum TimerLocation
{
    TimerLocation_Hint = 0,
    TimerLocation_Text,
    TimerLocation_Chat,
    TimerLocation_HUD
}

enum WarningType
{
    WarningType_Vote,
    WarningType_Revote
}

enum Convars
{
    ConVar:TimeLoc,
    ConVar:OldMaps,
    ConVar:NameTag,
}
// cvars
any g_Convars[Convars];

MapChange g_MapChange;

//credits: https://github.com/powerlord/sourcemod-mapchooser-extended
//credits: https://github.com/alliedmodders/sourcemod/blob/master/plugins/

public Plugin myinfo =
{
    name        = "MapChooser Redux",
    author      = "Kyle",
    description = "Automated Map Voting with Extensions",
    version     = MCR_VERSION,
    url         = "https://kxnrl.com"
};

public void OnPluginStart()
{
    SMUtils_SetChatPrefix("[\x02M\x04C\x0CR\x01]");
    SMUtils_SetChatSpaces("   ");
    SMUtils_SetChatConSnd(false);
    SMUtils_SetTextDest(HUD_PRINTCENTER);
    
    LoadTranslations("com.kxnrl.mcr.translations");

    int iArraySize = ByteCountToCells(256);
    
    g_aMapList          = new ArrayList(iArraySize);
    g_aNominateList     = new ArrayList(iArraySize);
    g_aNominateOwners   = new ArrayList();
    g_aOldMapList       = new ArrayList(iArraySize);
    g_aNextMapList      = new ArrayList(iArraySize);
    
    g_Convars[TimeLoc] = CreateConVar("mcr_timer_hud_location",  "3", "Timer Location of HUD - 0: Hint,  1: Text,  2: Chat,  3: Game", _, true, 0.0, true, 3.0);
    g_Convars[OldMaps] = CreateConVar("mcr_maps_history_count", "15", "How many maps cooldown",                                        _, true, 1.0, true, 300.0);
    g_Convars[NameTag] = CreateConVar("mcr_include_descnametag", "1", "include name tag in map desc",                                  _, true, 0.0, true, 1.0);

    if(!DirExists("cfg/sourcemod/mapchooser"))
        if(!CreateDirectory("cfg/sourcemod/mapchooser", 511))
            SetFailState("Failed to create folder \"cfg/sourcemod/mapchooser\"");

    AutoExecConfig(true, "mapchooser", "sourcemod/mapchooser");

    RegAdminCmd("sm_mapvote",    Command_Mapvote,    ADMFLAG_CHANGEMAP, "sm_mapvote - Forces MapChooser to attempt to run a map vote now.");
    RegAdminCmd("sm_setnextmap", Command_SetNextmap, ADMFLAG_CHANGEMAP, "sm_setnextmap <map>");
    RegAdminCmd("sm_clearcd",    Command_ClearCD,    ADMFLAG_CHANGEMAP, "sm_clearcd - Forces Mapchooser to clear map history and cooldown.");

    g_NominationsResetForward   = CreateGlobalForward("OnNominationRemoved",    ET_Ignore, Param_String, Param_Cell);
    g_MapVoteStartedForward     = CreateGlobalForward("OnMapVoteStarted",       ET_Ignore);
    g_MapVoteEndForward         = CreateGlobalForward("OnMapVoteEnd",           ET_Ignore, Param_String);
    g_MapDataLoadedForward      = CreateGlobalForward("OnMapDataLoaded",        ET_Ignore);

    HookEventEx("cs_win_panel_match",   Event_WinPanel, EventHookMode_Post);
    HookEventEx("round_end",            Event_RoundEnd, EventHookMode_Post);
    
    BuildKvMapData();
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if(!CleanPlugin())
    {
        strcopy(error, err_max, "can not clean files.");
        return APLRes_Failure;
    }

    RegPluginLibrary("mapchooser");

    CreateNative("NominateMap",             Native_NominateMap);
    CreateNative("RemoveNominationByMap",   Native_RemoveNominationByMap);
    CreateNative("RemoveNominationByOwner", Native_RemoveNominationByOwner);
    CreateNative("InitiateMapChooserVote",  Native_InitiateVote);
    CreateNative("CanMapChooserStartVote",  Native_CanVoteStart);
    CreateNative("HasEndOfMapVoteFinished", Native_CheckVoteDone);
    CreateNative("GetExcludeMapList",       Native_GetExcludeMapList);
    CreateNative("GetNominatedMapList",     Native_GetNominatedMapList);
    CreateNative("EndOfMapVoteEnabled",     Native_EndOfMapVoteEnabled);
    CreateNative("CanNominate",             Native_CanNominate);

    MarkNativeAsOptional("Store_GetClientCredits");
    MarkNativeAsOptional("Store_SetClientCredits");

    MarkNativeAsOptional("MG_Shop_GetClientMoney");
    MarkNativeAsOptional("MG_Shop_ClientEarnMoney");
    MarkNativeAsOptional("MG_Shop_ClientCostMoney");

    return APLRes_Success;
}

public void OnLibraryAdded(const char[] name)
{
    if(strcmp(name, "store") == 0)
        g_pStore = true;
    else if(strcmp(name, "shop-core") == 0)
        g_pShop = true;
}

public void OnLibraryRemoved(const char[] name)
{
    if(strcmp(name, "store") == 0)
        g_pStore = false;
    else if(strcmp(name, "shop-core") == 0)
        g_pShop = false;
}

public void OnConfigsExecuted()
{
    g_pStore = LibraryExists("store");
    g_pShop = LibraryExists("shop-core");

    if(ReadMapList(g_aMapList, g_iMapFileSerial, "mapchooser", MAPLIST_FLAG_CLEARARRAY|MAPLIST_FLAG_MAPSFOLDER) != null)
        if(g_iMapFileSerial == -1)
            SetFailState("Unable to create a valid map list.");
        
    CheckMapData();

    FindConVar("mp_endmatch_votenextmap").SetBool(false);

    CreateNextVote();
    SetupTimeleftTimer();

    g_iExtends = 0;
    g_bMapVoteCompleted = false;
    g_bChangeMapAtRoundEnd = false;
    g_iNominateCount = 0;

    g_aNominateList.Clear();
    g_aNominateOwners.Clear();

    if(g_aOldMapList.Length < 1)
    {
        char filepath[128];
        BuildPath(Path_SM, filepath, 128, "data/mapchooser_oldlist.txt");

        if(!FileExists(filepath))
            return;

        File file = OpenFile(filepath, "r");
        if(file != null)
        {
            g_aOldMapList.Clear();

            char fileline[128];

            while(file.ReadLine(fileline, 128))
            {
                TrimString(fileline);

                g_aOldMapList.PushString(fileline);

                if(g_aOldMapList.Length >= g_Convars[OldMaps].IntValue)
                    break;
            }

            file.Close();
        }
    }
}

public void OnMapEnd()
{
    g_bHasVoteStarted = false;
    g_bWaitingForVote = false;
    g_bChangeMapInProgress = false;

    g_tVote = null;
    g_tRetry = null;
    g_tWarning = null;
    g_iRunoffCount = 0;

    char map[128];
    GetCurrentMap(map, 128);
    g_aOldMapList.PushString(map);

    if(g_aOldMapList.Length > g_Convars[OldMaps].IntValue)
        g_aOldMapList.Erase(0);

    char filepath[128];
    BuildPath(Path_SM, filepath, 128, "data/mapchooser_oldlist.txt");

    if(FileExists(filepath))
        DeleteFile(filepath);

    File file = OpenFile(filepath, "w");

    if(file == null)
    {
        LogError("Open old map list fialed");
        return;
    }

    for(int i = 0; i < g_aOldMapList.Length; ++i)
    {
        g_aOldMapList.GetString(i, map, 128);
        file.WriteLine(map);
    }

    file.Close();
}

public void OnClientDisconnect(int client)
{
    int index = g_aNominateOwners.FindValue(client);

    if(index == -1)
        return;

    char oldmap[256];
    g_aNominateList.GetString(index, oldmap, 256);
    Call_StartForward(g_NominationsResetForward);
    Call_PushString(oldmap);
    Call_PushCell(g_aNominateOwners.Get(index));
    Call_Finish();

    g_aNominateOwners.Erase(index);
    g_aNominateList.Erase(index);
    g_iNominateCount--;
}

public Action Command_SetNextmap(int client, int args)
{
    if(args < 1)
    {
        ReplyToCommand(client, "[\x04MCR\x01]  Usage: sm_setnextmap <map>");
        return Plugin_Handled;
    }

    char map[256];
    GetCmdArg(1, map, 256);

    if(!IsMapValid(map))
    {
        ReplyToCommand(client, "[\x04MCR\x01]  地图无效[%s]", map);
        return Plugin_Handled;
    }

    LogAction(client, -1, "\"%L\" changed nextmap to \"%s\"", client, map);

    SetNextMap(map);
    g_bMapVoteCompleted = true;

    return Plugin_Handled;
}

public void OnMapTimeLeftChanged()
{
    if(g_aMapList.Length > 0)
        SetupTimeleftTimer();
}

void SetupTimeleftTimer()
{
    int timeLeft;
    if(GetMapTimeLeft(timeLeft) && timeLeft > 0)
    {
        if(timeLeft - 300 < 0 && !g_bMapVoteCompleted && !g_bHasVoteStarted) {
            SetupWarningTimer(WarningType_Vote);
		}
        else
        {
            if(g_tWarning == null)
            {
                if(g_tVote != null)
                {
                    KillTimer(g_tVote);
                    g_tVote = null;
                }

                g_tVote = CreateTimer(float(timeLeft - 300), Timer_StartWarningTimer, _, TIMER_FLAG_NO_MAPCHANGE);
            }
        }        
    }
}

public Action Timer_StartWarningTimer(Handle timer)
{
    g_tVote = null;
    
    if(!g_bWarningInProgress || g_tWarning == null)
        SetupWarningTimer(WarningType_Vote);

    return Plugin_Stop;
}

public Action Timer_StartMapVote(Handle timer, DataPack data)
{
    static int timePassed;

    if(!g_aMapList.Length || g_bMapVoteCompleted || g_bHasVoteStarted)
    {
        g_tWarning = null;
        return Plugin_Stop;
    }

    data.Reset();
    int warningMaxTime = data.ReadCell();
    int warningTimeRemaining = warningMaxTime - timePassed;

    switch(view_as<TimerLocation>(g_Convars[TimeLoc].IntValue))
    {
        case TimerLocation_Text: tTextAll("%t", "mcr countdown text hint", warningTimeRemaining);
        case TimerLocation_Chat: tChatAll("%t", "mcr countdown chat",      warningTimeRemaining);
        case TimerLocation_Hint: tHintAll("%t", "mcr countdown text hint", warningTimeRemaining);
        case TimerLocation_HUD:  DisplayCountdownHUD(warningTimeRemaining);
    }

    if(timePassed++ >= warningMaxTime)
    {
        if(timer == g_tRetry)
        {
            g_bWaitingForVote = false;
            g_tRetry = null;
        }
        else
        {
            g_tWarning = null;
        }
    
        timePassed = 0;
        MapChange mapChange = view_as<MapChange>(data.ReadCell());
        ArrayList arraylist = view_as<ArrayList>(data.ReadCell());

        InitiateVote(mapChange, arraylist);
        
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

public Action Command_Mapvote(int client, int args)
{
    tChatAll("%t", "mcr voting started");

    SetupWarningTimer(WarningType_Vote, MapChange_MapEnd, null, true);

    return Plugin_Handled;    
}

void InitiateVote(MapChange when, ArrayList inputlist)
{
    g_bWaitingForVote = true;
    g_bWarningInProgress = false;

    if(IsVoteInProgress())
    {
        LogMessage("IsVoteInProgress -> %d", FAILURE_TIMER_LENGTH);
        
        DataPack data = new DataPack();
        data.WriteCell(FAILURE_TIMER_LENGTH);
        data.WriteCell(when);
        data.WriteCell(inputlist);
        data.Reset();

        g_tRetry = CreateTimer(1.0, Timer_StartMapVote, data, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT|TIMER_DATA_HNDL_CLOSE);

        return;
    }

    if(g_bMapVoteCompleted && g_bChangeMapInProgress)
        return;

    SetHudTextParams(-1.0, 0.32, 3.5, 0, 255, 255, 255, 2, 0.3, 0.3, 0.3);
    for(int client = 1; client <= MaxClients; ++client)
        if(IsClientInGame(client) && !IsFakeClient(client))
            ShowHudText(client, 5, "%T", "mcr voting started", client);

    g_MapChange = when;
    
    g_bWaitingForVote = false;
    g_bHasVoteStarted = true;

    Handle menuStyle = GetMenuStyleHandle(view_as<MenuStyle>(0));

    if(menuStyle != INVALID_HANDLE)
        g_hVoteMenu = CreateMenuEx(menuStyle, Handler_MapVoteMenu, MenuAction_End | MenuAction_Display | MenuAction_DisplayItem | MenuAction_VoteCancel);
    else
        g_hVoteMenu = CreateMenu(Handler_MapVoteMenu, MenuAction_End | MenuAction_Display | MenuAction_DisplayItem | MenuAction_VoteCancel);

    Handle radioStyle = GetMenuStyleHandle(MenuStyle_Radio);

    if(GetMenuStyle(g_hVoteMenu) == radioStyle)
    {
        g_bBlockedSlots = true;
        AddMenuItem(g_hVoteMenu, LINE_ONE, "Choose something...", ITEMDRAW_DISABLED);
        AddMenuItem(g_hVoteMenu, LINE_TWO, "...will ya?", ITEMDRAW_DISABLED);
    }
    else
        g_bBlockedSlots = false;

    SetMenuOptionFlags(g_hVoteMenu, MENUFLAG_BUTTON_NOVOTE);

    SetMenuTitle(g_hVoteMenu, "选择下一张地图\n ");
    SetVoteResultCallback(g_hVoteMenu, Handler_MapVoteFinished);

    char map[256];

    if(inputlist == null)
    {
        int voteSize = 5;

        int nominationsToAdd = g_aNominateList.Length >= voteSize ? voteSize : g_aNominateList.Length;

        for(int i = 0; i < nominationsToAdd; i++)
        {
            g_aNominateList.GetString(i, map, 256);

            AddMapItem(g_hVoteMenu, map, g_Convars[NameTag].BoolValue);
            RemoveStringFromArray(g_aNextMapList, map);

            Call_StartForward(g_NominationsResetForward);
            Call_PushString(map);
            Call_PushCell(g_aNominateOwners.Get(i));
            Call_Finish();
        }

        for(int i = nominationsToAdd; i < g_aNominateList.Length; i++)
        {
            g_aNominateList.GetString(i, map, 256);

            Call_StartForward(g_NominationsResetForward);
            Call_PushString(map);
            Call_PushCell(g_aNominateOwners.Get(i));
            Call_Finish();
        }

        int i = nominationsToAdd;
        int count = 0;

        if(i < voteSize && g_aNextMapList.Length == 0)
        {
            if(i == 0)
            {
                ThrowError("No maps available for vote.");
                return;
            }
            else
            {
                LogMessage("Not enough maps to fill map list.");
                voteSize = i;
            }
        }

        while(i < voteSize)
        {
            GetArrayString(g_aNextMapList, count, map, 256);        
            count++;

            AddMapItem(g_hVoteMenu, map, g_Convars[NameTag].BoolValue);
            i++;

            if(count >= g_aNextMapList.Length)
                break;
        }

        g_iNominateCount = 0;
        g_aNominateOwners.Clear();
        g_aNominateList.Clear();

        AddExtendToMenu(g_hVoteMenu, when);
    }
    else
    {
        for(int i = 0; i < inputlist.Length; i++)
        {
            inputlist.GetString(i, map, 256);
            
            if(IsMapValid(map))
                AddMapItem(g_hVoteMenu, map, g_Convars[NameTag].BoolValue);
            else if(StrEqual(map, VOTE_DONTCHANGE))
                AddMenuItem(g_hVoteMenu, VOTE_DONTCHANGE, "Don't Change");
            else if(StrEqual(map, VOTE_EXTEND))
                AddMenuItem(g_hVoteMenu, VOTE_EXTEND, "Extend Map");
        }
        delete inputlist;
    }

    if(5 <= GetMaxPageItems(GetMenuStyle(g_hVoteMenu)))
        SetMenuPagination(g_hVoteMenu, MENU_NO_PAGINATION);
    
    VoteMenuToAll(g_hVoteMenu, 15);

    Call_StartForward(g_MapVoteStartedForward);
    Call_Finish();

    LogAction(-1, -1, "Voting for next map has started.");
    tChatAll("%t", "mcr voting started");
}

public void Handler_VoteFinishedGeneric(Menu menu, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
    char map[256];
    GetMapItem(menu, item_info[0][VOTEINFO_ITEM_INDEX], map, 256);

    Call_StartForward(g_MapVoteEndForward);
    Call_PushString(map);
    Call_Finish();

    if(strcmp(map, VOTE_EXTEND, false) == 0)
    {
        g_iExtends++;
        
        int timeLimit;
        if(GetMapTimeLimit(timeLimit))
            if(timeLimit > 0)
                ExtendMapTimeLimit(1200);                        

        tChatAll("%t", "mcr extend map", item_info[0][VOTEINFO_ITEM_VOTES], num_votes);
        LogAction(-1, -1, "Voting for next map has finished. The current map has been extended.");

        g_bHasVoteStarted = false;
        CreateNextVote();
        SetupTimeleftTimer();
    }
    else if(strcmp(map, VOTE_DONTCHANGE, false) == 0)
    {
        tChatAll("%t", "mcr dont change", item_info[0][VOTEINFO_ITEM_VOTES], num_votes);
        LogAction(-1, -1, "Voting for next map has finished. 'No Change' was the winner");
        
        g_bHasVoteStarted = false;
        CreateNextVote();
        SetupTimeleftTimer();
    }
    else
    {
        if(g_MapChange == MapChange_Instant)
        {
            g_bChangeMapInProgress = true;
            CreateTimer(10.0 , Timer_ChangeMaprtv);
        }
        else if(g_MapChange == MapChange_RoundEnd)
        {
            g_bChangeMapAtRoundEnd = true;
            SetConVarInt(FindConVar("mp_timelimit"), 1);
        }

        FindConVar("nextlevel").SetString(map);
        SetNextMap(map);

        g_bHasVoteStarted = false;
        g_bMapVoteCompleted = true;
        
        tChatAll("%t", "mcr next map", map, item_info[0][VOTEINFO_ITEM_VOTES], num_votes);
        LogAction(-1, -1, "Voting for next map has finished. Nextmap: %s.", map);
    }    
}

public void Event_RoundEnd(Handle event, const char[] name, bool dontBroadcast)
{
    if(!g_bChangeMapAtRoundEnd)
        return;

    FindConVar("mp_halftime").SetInt(0);
    FindConVar("mp_timelimit").SetInt(0);
    FindConVar("mp_maxrounds").SetInt(0);
    FindConVar("mp_roundtime").SetInt(1);

    CreateTimer(35.0, Timer_ChangeMap, 0, TIMER_FLAG_NO_MAPCHANGE);

    g_bChangeMapInProgress = true;
    g_bChangeMapAtRoundEnd = false;
}

public Action Timer_ChangeMaprtv(Handle hTimer)
{
    FindConVar("mp_halftime").SetInt(0);
    FindConVar("mp_timelimit").SetInt(0);
    FindConVar("mp_maxrounds").SetInt(0);
    FindConVar("mp_roundtime").SetInt(1);

    CS_TerminateRound(12.0, CSRoundEnd_Draw, true);

    CreateTimer(35.0, Timer_ChangeMap, 0, TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Stop;
}

public void Handler_MapVoteFinished(Menu menu, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
    if(num_items > 1 && g_iRunoffCount < 1)
    {
        g_iRunoffCount++;
        int highest_votes = item_info[0][VOTEINFO_ITEM_VOTES];
        int required_percent = 50;
        int required_votes = RoundToCeil(float(num_votes) * float(required_percent) / 100);
        
        if(highest_votes == item_info[1][VOTEINFO_ITEM_VOTES])
        {
            g_bHasVoteStarted = false;

            ArrayList mapList = new ArrayList(ByteCountToCells(256));

            for(int i = 0; i < num_items; i++)
            {
                if(item_info[i][VOTEINFO_ITEM_VOTES] == highest_votes)
                {
                    char map[256];
                    GetMapItem(menu, item_info[i][VOTEINFO_ITEM_INDEX], map, 256);
                    mapList.PushString(map);
                }
                else
                    break;
            }
            
            tChatAll("%t", "mcr tier", mapList.Length);
            SetupWarningTimer(WarningType_Revote, view_as<MapChange>(g_MapChange), mapList);
            return;
        }
        else if(highest_votes < required_votes)
        {
            g_bHasVoteStarted = false;

            ArrayList mapList = new ArrayList(ByteCountToCells(256));

            char map[256];
            GetMapItem(menu, item_info[0][VOTEINFO_ITEM_INDEX], map, 256);

            mapList.PushString(map);

            for(int i = 1; i < num_items; i++)
            {
                if(mapList.Length < 2 || item_info[i][VOTEINFO_ITEM_VOTES] == item_info[i - 1][VOTEINFO_ITEM_VOTES])
                {
                    GetMapItem(menu, item_info[i][VOTEINFO_ITEM_INDEX], map, 256);
                    mapList.PushString(map);
                }
                else
                    break;
            }
            tChatAll("%t", "mcr runoff", required_percent);
            SetupWarningTimer(WarningType_Revote, view_as<MapChange>(g_MapChange), mapList);
            return;
        }
    }

    Handler_VoteFinishedGeneric(menu, num_votes, num_clients, client_info, num_items, item_info);
}

public int Handler_MapVoteMenu(Handle menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_End:
        {
            g_hVoteMenu = null;
            delete menu;
        }
        case MenuAction_Display:
        {
            SetPanelTitle(view_as<Handle>(param2), "投票选择下幅地图 \n ");
        }
        case MenuAction_DisplayItem:
        {
            char map[256];
            char buffer[256];

            GetMenuItem(menu, param2, map, 256);

            if(StrEqual(map, VOTE_EXTEND, false))
                strcopy(buffer, 256, "延长当前地图");
            else if(StrEqual(map, VOTE_DONTCHANGE, false))
                strcopy(buffer, 256, "不要更换地图");
            else if(StrEqual(map, LINE_ONE, false))
                strcopy(buffer, 256, "选择你想玩的地铁图...");
            else if(StrEqual(map, LINE_TWO, false))
                strcopy(buffer, 256, "如果你选错可以输入 !revote 重新投票 ;-)");
            
            if(buffer[0] != '\0')
                return RedrawMenuItem(buffer);
        }
        case MenuAction_VoteCancel:
        {
            if(param1 == VoteCancel_NoVotes)
            {
                int count = GetMenuItemCount(menu);
                
                int item;
                char map[256];
                
                do
                {
                    int startInt = 0;
                    if(g_bBlockedSlots)
                        startInt = 2;
                    item = UTIL_GetRandomInt(startInt, count - 1);
                    GetMenuItem(menu, item, map, 256);
                }
                while(strcmp(map, VOTE_EXTEND, false) == 0);

                SetNextMap(map);
                g_bMapVoteCompleted = true;
            }
            g_bHasVoteStarted = false;
        }
    }

    return 0;
}

public Action Timer_ChangeMap(Handle timer)
{
    g_bChangeMapInProgress = false;

    char map[256];
    
    if(!GetNextMap(map, 256))
    {
        ThrowError("Timer_ChangeMap -> !GetNextMap");
        return Plugin_Stop;    
    }

    ForceChangeLevel(map, "Map Vote");
 
    return Plugin_Stop;
}

bool RemoveStringFromArray(ArrayList array, const char[] str)
{
    int index = array.FindString(str);
    if(index != -1)
    {
        array.Erase(index);
        return true;
    }

    return false;
}

void CreateNextVote()
{
    g_aNextMapList.Clear();

    ArrayList tempMaps = view_as<ArrayList>(CloneArray(g_aMapList));

    char map[256];
    GetCurrentMap(map, 256);
    RemoveStringFromArray(tempMaps, map);

    if(tempMaps.Length > g_Convars[OldMaps].IntValue)
    {
        for(int i = 0; i < g_aOldMapList.Length; i++)
        {
            g_aOldMapList.GetString(i, map, 256);
            RemoveStringFromArray(tempMaps, map);
        }
    }
    else LogError("no enough to create NextVote Maplist");

    for(int x = 0; x < tempMaps.Length; ++x)
    {
        tempMaps.GetString(x, map, 256);
        // we remove big maps( >150 will broken fastdl .bz2), nice map, and only nominations
        if(IsNiceMap(map) || IsBigMap(map) || IsOnlyNomination(map) || IsOnlyAdmin(map) || IsOnlyVIP(map))
        {
            RemoveStringFromArray(tempMaps, map);
            if(x > 0) x--;
        }
    }

    int players = GetClientCount(true); // no any ze server run with bot.
    for(int x = 0; x < tempMaps.Length; ++x)
    {
        tempMaps.GetString(x, map, 256);
        // we remove map if player amount not match with configs
        int max = GetMaxPlayers(map);
        int min = GetMinPlayers(map);
        if((min != 0 && players < min) || (max != 0 && players > max))
        {
            RemoveStringFromArray(tempMaps, map);
            if(x > 0) x--;
        }
    }

    int limit = (5 < tempMaps.Length ? 5 : tempMaps.Length);

    for(int i = 0; i < limit; i++)
    {
        int b = UTIL_GetRandomInt(0, GetArraySize(tempMaps) - 1);
        tempMaps.GetString(b, map, 256);
        g_aNextMapList.PushString(map);
        tempMaps.Erase(b);
    }

    delete tempMaps;
}

bool CanVoteStart()
{
    if(g_bWaitingForVote || g_bHasVoteStarted)
        return false;

    return true;
}

NominateResult InternalNominateMap(const char[] map, bool force, int owner)
{
    if(!IsMapValid(map))
        return NominateResult_InvalidMap;

    if(FindStringInArray(g_aNominateList, map) != -1)
        return NominateResult_AlreadyInVote;
    
    if(IsOnlyVIP(map) && !IsClientVIP(owner))
        return NominateResult_OnlyVIP;
    
    if(IsOnlyAdmin(map) && !CheckCommandAccess(owner, "sm_map", ADMFLAG_CHANGEMAP, false))
        return NominateResult_OnlyAdmin;

    int index;

    if(owner && ((index = g_aNominateOwners.FindValue(owner)) != -1))
    {
        char oldmap[256];
        g_aNominateList.GetString(index, oldmap, 256);
        InternalRemoveNominationByOwner(owner);

        if(g_pStore && Store_GetClientCredits(owner) < GetMapPrice(map))
            return NominateResult_NoCredits;
        
        if(g_pShop && MG_Shop_GetClientMoney(owner) < GetMapPrice(map))
            return NominateResult_NoCredits;

        g_aNominateList.PushString(map);
        g_aNominateOwners.Push(owner);

        return NominateResult_Replaced;
    }

    if(g_iNominateCount >= 5 && !force)
        return NominateResult_VoteFull;

    if(g_pStore && Store_GetClientCredits(owner) < GetMapPrice(map))
        return NominateResult_NoCredits;
    
    if(g_pShop && MG_Shop_GetClientMoney(owner) < GetMapPrice(map))
        return NominateResult_NoCredits;
    
    int max = GetMaxPlayers(map);
    if(max != 0 && GetClientCount(true) > max)
        return NominateResult_MaxPlayers;
    
    int min = GetMinPlayers(map);
    if(min != 0 && GetClientCount(true) < min)
        return NominateResult_MinPlayers;

    g_aNominateList.PushString(map);
    g_aNominateOwners.Push(owner);
    g_iNominateCount++;

    while(g_aNominateList.Length > 5)
    {
        char oldmap[256];
        g_aNominateList.GetString(0, oldmap, 256);
        Call_StartForward(g_NominationsResetForward);
        Call_PushString(oldmap);
        Call_PushCell(g_aNominateOwners.Get(0));
        Call_Finish();
        
        g_aNominateList.Erase(0);
        g_aNominateOwners.Erase(0);
    }

    return NominateResult_Added;
}

public int Native_NominateMap(Handle plugin, int numParams)
{
    int len;
    GetNativeStringLength(1, len);

    if(len <= 0)
      return false;

    char[] map = new char[len+1];
    GetNativeString(1, map, len+1);

    return view_as<int>(InternalNominateMap(map, GetNativeCell(2), GetNativeCell(3)));
}

bool InternalRemoveNominationByMap(const char[] map)
{
    for(int i = 0; i < g_aNominateList.Length; i++)
    {
        char oldmap[256];
        g_aNominateList.GetString(i, oldmap, 256);

        if(strcmp(map, oldmap, false) == 0)
        {
            Call_StartForward(g_NominationsResetForward);
            Call_PushString(oldmap);
            Call_PushCell(g_aNominateOwners.Get(i));
            Call_Finish();

            g_aNominateList.Erase(i);
            g_aNominateOwners.Erase(i);
            g_iNominateCount--;

            return true;
        }
    }
    
    return false;
}

public int Native_RemoveNominationByMap(Handle plugin, int numParams)
{
    int len;
    GetNativeStringLength(1, len);

    if(len <= 0)
      return false;
    
    char[] map = new char[len+1];
    GetNativeString(1, map, len+1);

    return InternalRemoveNominationByMap(map);
}

bool InternalRemoveNominationByOwner(int owner)
{    
    int index;

    if(owner && ((index = FindValueInArray(g_aNominateOwners, owner)) != -1))
    {
        char oldmap[256];
        g_aNominateList.GetString(index, oldmap, 256);

        Call_StartForward(g_NominationsResetForward);
        Call_PushString(oldmap);
        Call_PushCell(owner);
        Call_Finish();

        g_aNominateList.Erase(index);
        g_aNominateOwners.Erase(index);
        g_iNominateCount--;

        if(g_pStore)
        {
            int credits = GetMapPrice(oldmap);
            Store_SetClientCredits(owner, Store_GetClientCredits(owner)+credits, "nomination-退还");
            Chat(owner, "%T", "mcr nominate fallback", owner, oldmap, credits);
        }
        else if(g_pShop)
        {
            int credits = GetMapPrice(oldmap);
            MG_Shop_ClientEarnMoney(owner, credits, "nomination-退还");
            Chat(owner, "%T", "mcr nominate fallback", owner, oldmap, credits);
        }

        return true;
    }
    
    return false;
}

public int Native_RemoveNominationByOwner(Handle plugin, int numParams)
{    
    return InternalRemoveNominationByOwner(GetNativeCell(1));
}

public int Native_InitiateVote(Handle plugin, int numParams)
{
    MapChange when = view_as<MapChange>(GetNativeCell(1));
    ArrayList maps = view_as<ArrayList>(GetNativeCell(2));

    LogAction(-1, -1, "Starting map vote because outside request");

    SetupWarningTimer(WarningType_Vote, when, maps);
}

public int Native_CanVoteStart(Handle plugin, int numParams)
{
    return CanVoteStart();    
}

public int Native_CheckVoteDone(Handle plugin, int numParams)
{
    return g_bMapVoteCompleted;
}

public int Native_GetExcludeMapList(Handle plugin, int numParams)
{
    ArrayList array = view_as<ArrayList>(GetNativeCell(1));
    
    if(array == null)
        return;

    char map[256];

    for(int i = 0; i < g_aOldMapList.Length; i++)
    {
        g_aOldMapList.GetString(i, map, 256);
        array.PushString(map);
    }
}

public int Native_GetNominatedMapList(Handle plugin, int numParams)
{
    ArrayList maps = view_as<ArrayList>(GetNativeCell(1));
    ArrayList owns = view_as<ArrayList>(GetNativeCell(2));

    if(maps == null)
        return;

    char map[256];

    for(int i = 0; i < g_aNominateList.Length; i++)
    {
        g_aNominateList.GetString(i, map, 256);
        maps.PushString(map);

        if(owns != null)
        {
            int index = g_aNominateOwners.Get(i);
            owns.Push(index);
        }
    }
}

public int Native_EndOfMapVoteEnabled(Handle plugin, int numParams)
{
    return true;
}

stock int SetupWarningTimer(WarningType type, MapChange when = MapChange_MapEnd, Handle mapList = null, bool force = false)
{
    if(g_aMapList.Length <= 0 || g_bChangeMapInProgress || g_bHasVoteStarted || (!force && g_bMapVoteCompleted))
        return;

    if(g_bWarningInProgress && g_tWarning != null)
        KillTimer(g_tWarning);

    g_bWarningInProgress = true;
    
    int cvarTime;

    switch (type)
    {
        case WarningType_Vote:
        {
            cvarTime = 15;
        }
        
        case WarningType_Revote:
        {
            cvarTime = 5;
        }
    }

    DataPack data = new DataPack();
    data.WriteCell(cvarTime);
    data.WriteCell(when);
    data.WriteCell(mapList);
    data.Reset();
    g_tWarning = CreateTimer(1.0, Timer_StartMapVote, data, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT|TIMER_DATA_HNDL_CLOSE);
}

stock bool IsMapEndVoteAllowed()
{
    if(g_bMapVoteCompleted || g_bHasVoteStarted)
        return false;
    else
        return true;
}

public int Native_IsWarningTimer(Handle plugin, int numParams)
{
    return g_bWarningInProgress;
}

public int Native_CanNominate(Handle plugin, int numParams)
{
    if(g_bHasVoteStarted)
        return view_as<int>(CanNominate_No_VoteInProgress);
    
    if(g_bMapVoteCompleted)
        return view_as<int>(CanNominate_No_VoteComplete);
    
    if(g_iNominateCount >= 5)
        return view_as<int>(CanNominate_No_VoteFull);
    
    return view_as<int>(CanNominate_Yes);
}

void BuildKvMapData()
{
    if(g_hKvMapData != null)
        delete g_hKvMapData;

    g_hKvMapData = new KeyValues("MapData", "", "");

    if(!FileExists("addons/sourcemod/configs/mapdata.txt"))
        g_hKvMapData.ExportToFile("addons/sourcemod/configs/mapdata.txt");
    else
        g_hKvMapData.ImportFromFile("addons/sourcemod/configs/mapdata.txt");

    g_hKvMapData.Rewind();
}

bool ManuallyAddMapData(const char[] map)
{
    if(g_hKvMapData == null)
    {
        ThrowError("ManuallyAddMapData -> Data Handle is null");
        return false;
    }

    g_hKvMapData.Rewind();

    if(!g_hKvMapData.JumpToKey(map))
    {
        char path[128];
        FormatEx(path, 128, "maps/%s.bsp", map);

        g_hKvMapData.JumpToKey(map, true);

        g_hKvMapData.SetString("desc", "null: unknown");

        g_hKvMapData.SetNum("price",            100);
        g_hKvMapData.SetNum("size",             FileSize(path)/1048576+1);
        g_hKvMapData.SetNum("nice",             0);
        g_hKvMapData.SetNum("minplayers",       0);
        g_hKvMapData.SetNum("maxplayers",       0);
        g_hKvMapData.SetNum("nominationonly",   0);
        g_hKvMapData.SetNum("adminonly",        0);
        g_hKvMapData.SetNum("viponly",          0);

        return true;
    }

    return false;
}

void CheckMapData()
{
    if(g_hKvMapData == null)
    {
        ThrowError("CheckMapData -> Data Handle is null");
        return;
    }
    g_hKvMapData.Rewind();
    
    char map[128];
    bool changed = false;

    if(g_hKvMapData.GotoFirstSubKey(true))
    {
        char path[128];
        do
        {
            g_hKvMapData.GetSectionName(map, 128);
            FormatEx(path, 128, "maps/%s.bsp", map);
            if(!FileExists(path))
            {
                LogMessage("Delete %s from mapdata", map);
                g_hKvMapData.DeleteThis();
                changed = true;
            }
        }
        while(g_hKvMapData.GotoNextKey(true));
    }

    for(int i = 0; i < g_aMapList.Length; ++i)
    {
        g_aMapList.GetString(i, map, 128);
        if(ManuallyAddMapData(map))
            changed = true;
    }

    g_hKvMapData.Rewind();

    if(changed)
        g_hKvMapData.ExportToFile("addons/sourcemod/configs/mapdata.txt");

    Call_StartForward(g_MapDataLoadedForward);
    Call_Finish();
}

public void Event_WinPanel(Handle event, const char[] name, bool dontBroadcast)
{
    char cmap[128], nmap[128];
    GetCurrentMap(cmap, 128);
    GetNextMap(nmap, 128);
    if(!IsMapValid(nmap))
    {
        do
        {
            g_aMapList.GetString(UTIL_GetRandomInt(0, GetArraySize(g_aMapList)-1), nmap, 128);
        }
        while(StrEqual(nmap, cmap));
    }

    DataPack pack = new DataPack();
    pack.WriteString(nmap);
    pack.Reset();
    CreateDataTimer(35.0, Timer_Monitor, pack, TIMER_FLAG_NO_MAPCHANGE|TIMER_DATA_HNDL_CLOSE);
}

public Action Timer_Monitor(Handle timer, DataPack pack)
{
    char cmap[128], nmap[128];
    GetCurrentMap(cmap, 128);
    pack.ReadString(nmap, 128);

    if(StrEqual(nmap, cmap))
        return Plugin_Stop;

    ThrowError("Map has not been changed ? %s -> %s", cmap, nmap);
    ForceChangeLevel(nmap, "BUG: Map not change");
    //ServerCommand("map %s", nmap);

    return Plugin_Stop;
}

public Action Command_ClearCD(int client, int args)
{
    g_aOldMapList.Clear();
    tChatAll("%t", "mcr clear cd");
    return Plugin_Handled;
}

stock void GetMapItem(Handle menu, int position, char[] map, int mapLen)
{
    GetMenuItem(menu, position, map, mapLen);
}

stock void AddExtendToMenu(Handle menu, MapChange when)
{
    if(when == MapChange_Instant || when == MapChange_RoundEnd)
        AddMenuItem(menu, VOTE_DONTCHANGE, "Don't Change");
    else if(g_iExtends < 3)
        AddMenuItem(menu, VOTE_EXTEND, "Extend Map");
}

stock bool IsClientVIP(int client)
{
    return CheckCommandAccess(client, "check_isclientvip", ADMFLAG_RESERVATION, false);
}

stock void DisplayCountdownHUD(int time)
{
    SetHudTextParams(-1.0, 0.32, 1.2, 0, 255, 255, 255, 0, 30.0, 0.0, 0.0);// Doc -> https://sm.alliedmods.net/new-api/halflife/SetHudTextParams
    for(int client = 1; client <= MaxClients; ++client)
        if(IsClientInGame(client) && !IsFakeClient(client))
            ShowHudText(client, 5, "%T", "mcr countdown hud", client, time); // 叁生鉐 is dead...
}

stock bool CleanPlugin()
{
    // delete mapchooser
    if(FileExists("addons/sourcemod/plugins/mapchooser.smx"))
        if(!DeleteFile("addons/sourcemod/plugins/mapchooser.smx"))
            return false;
    
    // delete rockthevote
    if(FileExists("addons/sourcemod/plugins/rockthevote.smx"))
        if(!DeleteFile("addons/sourcemod/plugins/rockthevote.smx"))
            return false;
        
    // delete nominations
    if(FileExists("addons/sourcemod/plugins/nominations.smx"))
        if(!DeleteFile("addons/sourcemod/plugins/nominations.smx"))
            return false;
        
    // delete mapchooser_extended
    if(FileExists("addons/sourcemod/plugins/mapchooser_extended.smx"))
        if(!DeleteFile("addons/sourcemod/plugins/mapchooser_extended.smx"))
            return false;
    
    // delete rockthevote_extended
    if(FileExists("addons/sourcemod/plugins/rockthevote_extended.smx"))
        if(!DeleteFile("addons/sourcemod/plugins/rockthevote_extended.smx"))
            return false;
        
    // delete nominations_extended
    if(FileExists("addons/sourcemod/plugins/nominations_extended.smx"))
        if(!DeleteFile("addons/sourcemod/plugins/nominations_extended.smx"))
            return false;

    return true;
}