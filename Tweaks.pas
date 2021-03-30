unit Tweaks;
{
DESCRIPTION:  Game improvements
AUTHOR:       Alexander Shostak (aka Berserker aka EtherniDee aka BerSoft)
}

(***)  interface  (***)
uses
  SysUtils, Utils, StrLib, WinSock, Windows, Math,
  CFiles, Files, FilesEx, Ini, DataLib, Concur, DlgMes, WinNative, RandMt, Stores,
  PatchApi, ApiJack, Core, GameExt, Heroes, Lodman, Erm, EventMan;

type
  (* Import *)
  TStrList = DataLib.TStrList;

const
  // f (Value: pchar; MaxResLen: integer; DefValue, Key, SectionName, FileName: pchar): integer; cdecl;
  ZvsReadStrIni  = Ptr($773A46);
  // f (Res: pinteger; DefValue: integer; Key, SectionName, FileName: pchar): integer; cdecl;
  ZvsReadIntIni  = Ptr($7739D1);
  // f (Value: pchar; Key, SectionName, FileName: pchar): integer; cdecl;
  ZvsWriteStrIni = Ptr($773B34);
  // f (Value, Key, SectionName, FileName: pchar): integer; cdecl;
  ZvsWriteIntIni = Ptr($773ACB);

  ZvsAppliedDamage: pinteger = Ptr($2811888);
  CurrentMp3Track:  pchar = pointer($6A33F4);


var
  (* Desired level of CPU loading *)
  CpuTargetLevel: integer;

  FixGetHostByNameOpt:  boolean;
  UseOnlyOneCpuCoreOpt: boolean;
  CombatRound:          integer;
  HadTacticsPhase:      boolean;


(***) implementation (***)


const
  RNG_SAVE_SECTION = 'Era.RNG';

type
  TWogMp3Process = procedure; stdcall;

var
{O} TopLevelExceptionHandlers: DataLib.TList {OF Handler: pointer};

  hTimerEvent:           THandle;
  InetCriticalSection:   Windows.TRTLCriticalSection;
  ExceptionsCritSection: Concur.TCritSection;
  ZvsLibImageTemplate:   string;
  ZvsLibGamePath:        string;
  IsLocalPlaceObject:    boolean = true;

  Mp3TriggerHandledEvent: THandle;
  IsMp3Trigger:           boolean = false;
  WogCurrentMp3TrackPtr:  ppchar = pointer($28AB204);
  WoGMp3Process:          TWogMp3Process = pointer($77495F);

threadvar
  (* Counter (0..100). When reaches 100, PeekMessageA does not call sleep before returning result *)
  CpuPatchCounter: integer;
  IsMainThread:    boolean;


function Hook_ReadIntIni
(
  Res:          pinteger;
  DefValue:     integer;
  Key:          pchar;
  SectionName:  pchar;
  FileName:     pchar
): integer; cdecl;

var
  Value:  string;

begin
  result  :=  0;

  if
    (not Ini.ReadStrFromIni(Key, SectionName, FileName, Value)) or
    not SysUtils.TryStrToInt(Value, Res^)
  then begin
    Res^  :=  DefValue;
  end;
end; // .function Hook_ReadIntIni

function Hook_ReadStrIni
(
  Res:          pchar;
  MaxResLen:    integer;
  DefValue:     pchar;
  Key:          pchar;
  SectionName:  pchar;
  FileName:     pchar
): integer; cdecl;

var
  Value:  string;

begin
  result  :=  0;

  if
    (not Ini.ReadStrFromIni(Key, SectionName, FileName, Value)) or
    (Length(Value) > MaxResLen)
  then begin
    Value :=  DefValue;
  end;

  if Value <> '' then begin
    Utils.CopyMem(Length(Value) + 1, pointer(Value), Res);
  end else begin
    Res^  :=  #0;
  end;
end; // .function Hook_ReadStrIni

function Hook_WriteStrIni (Value, Key, SectionName, FileName: pchar): integer; cdecl;
begin
  result  :=  0;

  if Ini.WriteStrToIni(Key, Value, SectionName, FileName) then begin
    Ini.SaveIni(FileName);
  end;
end;

function Hook_WriteIntIni (Value: integer; Key, SectionName, FileName: pchar): integer; cdecl;
begin
  result  :=  0;

  if Ini.WriteStrToIni(Key, SysUtils.IntToStr(Value), SectionName, FileName) then begin
    Ini.SaveIni(FileName);
  end;
end;

function Hook_ZvsGetWindowWidth (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  Context.ECX :=  WndManagerPtr^.ScreenPcx16.Width;
  result      :=  not Core.EXEC_DEF_CODE;
end;

function Hook_ZvsGetWindowHeight (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  Context.EDX :=  WndManagerPtr^.ScreenPcx16.Height;
  result      :=  not Core.EXEC_DEF_CODE;
end;

procedure MarkFreshestSavegame;
var
{O} Locator:          Files.TFileLocator;
{O} FileInfo:         Files.TFileItemInfo;
    FileName:         string;
    FreshestTime:     INT64;
    FreshestFileName: string;

begin
  Locator   :=  Files.TFileLocator.Create;
  FileInfo  :=  nil;
  // * * * * * //
  FreshestFileName  :=  #0;
  FreshestTime      :=  0;

  Locator.DirPath   :=  'Games';
  Locator.InitSearch('*.*');

  while Locator.NotEnd do begin
    FileName  :=  Locator.GetNextItem(CFiles.TItemInfo(FileInfo));

    if
      ((FileInfo.Data.dwFileAttributes and Windows.FILE_ATTRIBUTE_DIRECTORY) = 0) and
      (INT64(FileInfo.Data.ftLastWriteTime) > FreshestTime)
    then begin
      FreshestFileName  :=  FileName;
      FreshestTime      :=  INT64(FileInfo.Data.ftLastWriteTime);
    end;
    SysUtils.FreeAndNil(FileInfo);
  end; // .while

  Locator.FinitSearch;

  Utils.CopyMem(Length(FreshestFileName) + 1, pointer(FreshestFileName), Heroes.MarkedSavegame);
  // * * * * * //
  SysUtils.FreeAndNil(Locator);
end; // .procedure MarkFreshestSavegame

function Hook_SetHotseatHeroName (Context: Core.PHookContext): LONGBOOL; stdcall;
var
  PlayerName:     string;
  NewPlayerName:  string;
  EcxReg:         integer;

begin
  PlayerName    :=  pchar(Context.EAX);
  NewPlayerName :=  PlayerName + ' 1';
  EcxReg        :=  Context.ECX;

  asm
    MOV ECX, EcxReg
    PUSH NewPlayerName
    MOV EDX, [ECX]
    CALL [EDX + $34]
  end; // .asm

  NewPlayerName :=  PlayerName + ' 2';
  EcxReg        :=  Context.EBX;

  asm
    MOV ECX, EcxReg
    MOV ECX, [ECX + $54]
    PUSH NewPlayerName
    MOV EDX, [ECX]
    CALL [EDX + $34]
  end; // .asm

  result := not Core.EXEC_DEF_CODE;
end; // .function Hook_SetHotseatHeroName

function Hook_PeekMessageA (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  Inc(CpuPatchCounter, CpuTargetLevel);

  if CpuPatchCounter >= 100 then begin
    Dec(CpuPatchCounter, 100);
  end else begin
    Windows.WaitForSingleObject(hTimerEvent, 1);
  end;

  result := Core.EXEC_DEF_CODE;
end;

function New_Zvslib_GetPrivateProfileStringA
(
  Section:  pchar;
  Key:      pchar;
  DefValue: pchar;
  Buf:      pchar;
  BufSize:  integer;
  FileName: pchar
): integer; stdcall;

var
  Res:  string;

begin
  Res :=  '';

  if not Ini.ReadStrFromIni(Key, Section, FileName, Res) then begin
    Res :=  DefValue;
  end;

  if BufSize <= Length(Res) then begin
    SetLength(Res, BufSize - 1);
  end;

  Utils.CopyMem(Length(Res) + 1, pchar(Res), Buf);

  result :=  Length(Res) + 1;
end; // .function New_Zvslib_GetPrivateProfileStringA

procedure ReadGameSettings;
  procedure ReadInt (const Key: string; Res: pinteger);
  var
    StrValue: string;
    Value:    integer;

  begin
    if
      Ini.ReadStrFromIni
      (
        Key,
        Heroes.GAME_SETTINGS_SECTION,
        Heroes.GAME_SETTINGS_FILE,
        StrValue
      ) and
      SysUtils.TryStrToInt(StrValue, Value)
    then begin
      Res^  :=  Value;
    end; // .if
  end; // .procedure ReadInt

  procedure ReadStr (const Key: string; Res: pchar);
  var
    StrValue: string;

  begin
    if
      Ini.ReadStrFromIni(Key, Heroes.GAME_SETTINGS_SECTION, Heroes.GAME_SETTINGS_FILE, StrValue)
    then begin
      Utils.CopyMem(Length(StrValue) + 1, pchar(StrValue), Res);
    end;
  end; // .procedure ReadStr

const
  UNIQUE_ID_LEN   = 3;
  UNIQUE_ID_MASK  = $FFF;

var
  RandomValue:  integer;
  RandomStr:    string;
  i:            integer;

begin
  asm
    MOV EAX, Heroes.LOAD_DEF_SETTINGS
    CALL EAX
  end; // .asm

  ReadInt('Show Intro',             Heroes.SHOW_INTRO_OPT);
  ReadInt('Music Volume',           Heroes.MUSIC_VOLUME_OPT);
  ReadInt('Sound Volume',           Heroes.SOUND_VOLUME_OPT);
  ReadInt('Last Music Volume',      Heroes.LAST_MUSIC_VOLUME_OPT);
  ReadInt('Last Sound Volume',      Heroes.LAST_SOUND_VOLUME_OPT);
  ReadInt('Walk Speed',             Heroes.WALK_SPEED_OPT);
  ReadInt('Computer Walk Speed',    Heroes.COMP_WALK_SPEED_OPT);
  ReadInt('Show Route',             Heroes.SHOW_ROUTE_OPT);
  ReadInt('Move Reminder',          Heroes.MOVE_REMINDER_OPT);
  ReadInt('Quick Combat',           Heroes.QUICK_COMBAT_OPT);
  ReadInt('Video Subtitles',        Heroes.VIDEO_SUBTITLES_OPT);
  ReadInt('Town Outlines',          Heroes.TOWN_OUTLINES_OPT);
  ReadInt('Animate SpellBook',      Heroes.ANIMATE_SPELLBOOK_OPT);
  ReadInt('Window Scroll Speed',    Heroes.WINDOW_SCROLL_SPEED_OPT);
  ReadInt('Bink Video',             Heroes.BINK_VIDEO_OPT);
  ReadInt('Blackout Computer',      Heroes.BLACKOUT_COMPUTER_OPT);
  ReadInt('First Time',             Heroes.FIRST_TIME_OPT);
  ReadInt('Test Decomp',            Heroes.TEST_DECOMP_OPT);
  ReadInt('Test Read',              Heroes.TEST_READ_OPT);
  ReadInt('Test Blit',              Heroes.TEST_BLIT_OPT);
  ReadStr('Unique System ID',       Heroes.UNIQUE_SYSTEM_ID_OPT);

  if Heroes.UNIQUE_SYSTEM_ID_OPT^ = #0 then begin
    Randomize;
    RandomValue :=  (integer(Windows.GetTickCount) + Random(MAXLONGINT)) and UNIQUE_ID_MASK;
    SetLength(RandomStr, UNIQUE_ID_LEN);

    for i:=1 to UNIQUE_ID_LEN do begin
      RandomStr[i]  :=  UPCASE(StrLib.ByteToHexChar(RandomValue and $F));
      RandomValue   :=  RandomValue shr 4;
    end;

    Utils.CopyMem(Length(RandomStr) + 1, pointer(RandomStr), Heroes.UNIQUE_SYSTEM_ID_OPT);

    Ini.WriteStrToIni
    (
      'Unique System ID',
      RandomStr,
      Heroes.GAME_SETTINGS_SECTION,
      Heroes.GAME_SETTINGS_FILE
    );

    Ini.SaveIni(Heroes.GAME_SETTINGS_FILE);
  end; // .if

  ReadStr('Network default Name',   Heroes.NETWORK_DEF_NAME_OPT);
  ReadInt('Autosave',               Heroes.AUTOSAVE_OPT);
  ReadInt('Show Combat Grid',       Heroes.SHOW_COMBAT_GRID_OPT);
  ReadInt('Show Combat Mouse Hex',  Heroes.SHOW_COMBAT_MOUSE_HEX_OPT);
  ReadInt('Combat Shade Level',     Heroes.COMBAT_SHADE_LEVEL_OPT);
  ReadInt('Combat Army Info Level', Heroes.COMBAT_ARMY_INFO_LEVEL_OPT);
  ReadInt('Combat Auto Creatures',  Heroes.COMBAT_AUTO_CREATURES_OPT);
  ReadInt('Combat Auto Spells',     Heroes.COMBAT_AUTO_SPELLS_OPT);
  ReadInt('Combat Catapult',        Heroes.COMBAT_CATAPULT_OPT);
  ReadInt('Combat Ballista',        Heroes.COMBAT_BALLISTA_OPT);
  ReadInt('Combat First Aid Tent',  Heroes.COMBAT_FIRST_AID_TENT_OPT);
  ReadInt('Combat Speed',           Heroes.COMBAT_SPEED_OPT);
  ReadInt('Main Game Show Menu',    Heroes.MAIN_GAME_SHOW_MENU_OPT);
  ReadInt('Main Game X',            Heroes.MAIN_GAME_X_OPT);
  ReadInt('Main Game Y',            Heroes.MAIN_GAME_Y_OPT);
  ReadInt('Main Game Full Screen',  Heroes.MAIN_GAME_FULL_SCREEN_OPT);
  ReadStr('AppPath',                Heroes.APP_PATH_OPT);
  ReadStr('CDDrive',                Heroes.CD_DRIVE_OPT);
end; // .procedure ReadGameSettings

procedure WriteGameSettings;
  procedure WriteInt (const Key: string; Value: pinteger);
  begin
    Ini.WriteStrToIni
    (
      Key,
      SysUtils.IntToStr(Value^),
      Heroes.GAME_SETTINGS_SECTION,
      Heroes.GAME_SETTINGS_FILE
    );
  end;

  procedure WriteStr (const Key: string; Value: pchar);
  begin
    Ini.WriteStrToIni
    (
      Key,
      Value,
      Heroes.GAME_SETTINGS_SECTION,
      Heroes.GAME_SETTINGS_FILE
    );
  end;

begin
  WriteInt('Show Intro',             Heroes.SHOW_INTRO_OPT);
  WriteInt('Music Volume',           Heroes.MUSIC_VOLUME_OPT);
  WriteInt('Sound Volume',           Heroes.SOUND_VOLUME_OPT);
  WriteInt('Last Music Volume',      Heroes.LAST_MUSIC_VOLUME_OPT);
  WriteInt('Last Sound Volume',      Heroes.LAST_SOUND_VOLUME_OPT);
  WriteInt('Walk Speed',             Heroes.WALK_SPEED_OPT);
  WriteInt('Computer Walk Speed',    Heroes.COMP_WALK_SPEED_OPT);
  WriteInt('Show Route',             Heroes.SHOW_ROUTE_OPT);
  WriteInt('Move Reminder',          Heroes.MOVE_REMINDER_OPT);
  WriteInt('Quick Combat',           Heroes.QUICK_COMBAT_OPT);
  WriteInt('Video Subtitles',        Heroes.VIDEO_SUBTITLES_OPT);
  WriteInt('Town Outlines',          Heroes.TOWN_OUTLINES_OPT);
  WriteInt('Animate SpellBook',      Heroes.ANIMATE_SPELLBOOK_OPT);
  WriteInt('Window Scroll Speed',    Heroes.WINDOW_SCROLL_SPEED_OPT);
  WriteInt('Bink Video',             Heroes.BINK_VIDEO_OPT);
  WriteInt('Blackout Computer',      Heroes.BLACKOUT_COMPUTER_OPT);
  WriteInt('First Time',             Heroes.FIRST_TIME_OPT);
  WriteInt('Test Decomp',            Heroes.TEST_DECOMP_OPT);
  WriteInt('Test Write',             Heroes.TEST_READ_OPT);
  WriteInt('Test Blit',              Heroes.TEST_BLIT_OPT);
  WriteStr('Unique System ID',       Heroes.UNIQUE_SYSTEM_ID_OPT);
  WriteStr('Network default Name',   Heroes.NETWORK_DEF_NAME_OPT);
  WriteInt('Autosave',               Heroes.AUTOSAVE_OPT);
  WriteInt('Show Combat Grid',       Heroes.SHOW_COMBAT_GRID_OPT);
  WriteInt('Show Combat Mouse Hex',  Heroes.SHOW_COMBAT_MOUSE_HEX_OPT);
  WriteInt('Combat Shade Level',     Heroes.COMBAT_SHADE_LEVEL_OPT);
  WriteInt('Combat Army Info Level', Heroes.COMBAT_ARMY_INFO_LEVEL_OPT);
  WriteInt('Combat Auto Creatures',  Heroes.COMBAT_AUTO_CREATURES_OPT);
  WriteInt('Combat Auto Spells',     Heroes.COMBAT_AUTO_SPELLS_OPT);
  WriteInt('Combat Catapult',        Heroes.COMBAT_CATAPULT_OPT);
  WriteInt('Combat Ballista',        Heroes.COMBAT_BALLISTA_OPT);
  WriteInt('Combat First Aid Tent',  Heroes.COMBAT_FIRST_AID_TENT_OPT);
  WriteInt('Combat Speed',           Heroes.COMBAT_SPEED_OPT);
  WriteInt('Main Game Show Menu',    Heroes.MAIN_GAME_SHOW_MENU_OPT);
  WriteInt('Main Game X',            Heroes.MAIN_GAME_X_OPT);
  WriteInt('Main Game Y',            Heroes.MAIN_GAME_Y_OPT);
  WriteInt('Main Game Full Screen',  Heroes.MAIN_GAME_FULL_SCREEN_OPT);
  WriteStr('AppPath',                Heroes.APP_PATH_OPT);
  WriteStr('CDDrive',                Heroes.CD_DRIVE_OPT);

  Ini.SaveIni(Heroes.GAME_SETTINGS_FILE);
end; // .procedure WriteGameSettings

function Hook_GetHostByName (Hook: PatchApi.THiHook; Name: pchar): WinSock.PHostEnt; stdcall;
type
  PEndlessPIntArr = ^TEndlessPIntArr;
  TEndlessPIntArr = array [0..MAXLONGINT div 4 - 1] of pinteger;

var
{U} HostEnt:  WinSock.PHostEnt;
{U} Addrs:    PEndlessPIntArr;
    i:        integer;

  function IsLocalAddr (Addr: integer): boolean;
  type
    TInt32 = packed array [0..3] of byte;

  begin
    result := (TInt32(Addr)[0] = 10) or ((TInt32(Addr)[0] = 172) and Math.InRange(TInt32(Addr)[1],
                                                                                  16, 31)) or
                                        ((TInt32(Addr)[0] = 192) and (TInt32(Addr)[1] = 168));
  end;

begin
  {!} Windows.EnterCriticalSection(InetCriticalSection);

  result := Ptr(PatchApi.Call(PatchApi.STDCALL_, Hook.GetDefaultFunc(), [Name]));
  HostEnt := result;

  if HostEnt.h_length = sizeof(integer) then begin
    Addrs := pointer(HostEnt.h_addr_list);

    if (Addrs[0] <> nil) and IsLocalAddr(Addrs[0]^) then begin
      i := 1;

      while (Addrs[i] <> nil) and IsLocalAddr(Addrs[i]^) do begin
        Inc(i);
      end;

      if Addrs[i] <> nil then begin
        Utils.Exchange(Addrs[0]^, Addrs[i]^);
      end;
    end; // .if
  end; // .if

  {!} Windows.LeaveCriticalSection(InetCriticalSection);
end; // .function Hook_GetHostByName

function Hook_ApplyDamage_Ebx (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  Context.EBX := ZvsAppliedDamage^;
  result      := Core.EXEC_DEF_CODE;
end;

function Hook_ApplyDamage_Esi (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  Context.ESI := ZvsAppliedDamage^;
  result      := Core.EXEC_DEF_CODE;
end;

function Hook_ApplyDamage_Esi_Arg1 (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  Context.ESI                 := ZvsAppliedDamage^;
  pinteger(Context.EBP + $8)^ := ZvsAppliedDamage^;
  result                      := Core.EXEC_DEF_CODE;
end;

function Hook_ApplyDamage_Arg1 (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  pinteger(Context.EBP + $8)^ :=  ZvsAppliedDamage^;
  result                      :=  Core.EXEC_DEF_CODE;
end;

function Hook_ApplyDamage_Ebx_Local7 (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  Context.EBX                    := ZvsAppliedDamage^;
  pinteger(Context.EBP - 7 * 4)^ := ZvsAppliedDamage^;
  result                         := Core.EXEC_DEF_CODE;
end;

function Hook_ApplyDamage_Local7 (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  pinteger(Context.EBP - 7 * 4)^ := ZvsAppliedDamage^;
  result                         := Core.EXEC_DEF_CODE;
end;

function Hook_ApplyDamage_Local4 (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  pinteger(Context.EBP - 4 * 4)^ := ZvsAppliedDamage^;
  result                         := Core.EXEC_DEF_CODE;
end;

function Hook_ApplyDamage_Local8 (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  pinteger(Context.EBP - 8 * 4)^ := ZvsAppliedDamage^;
  result                         := Core.EXEC_DEF_CODE;
end;

function Hook_ApplyDamage_Local13 (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  pinteger(Context.EBP - 13 * 4)^ := ZvsAppliedDamage^;
  result                          := Core.EXEC_DEF_CODE;
end;

function Hook_GetWoGAndErmVersions (Context: Core.PHookContext): LONGBOOL; stdcall;
const
  NEW_WOG_VERSION = 400;

begin
  pinteger(Context.EBP - $0C)^ := NEW_WOG_VERSION;
  pinteger(Context.EBP - $24)^ := GameExt.ERA_VERSION_INT;
  result                       := not Core.EXEC_DEF_CODE;
end;

function Hook_ZvsLib_ExtractDef (Context: Core.PHookContext): LONGBOOL; stdcall;
const
  MIN_NUM_TOKENS = 2;
  TOKEN_LODNAME  = 0;
  TOKEN_DEFNAME  = 1;

  EBP_ARG_IMAGE_TEMPLATE = 16;

var
  ImageSettings: string;
  Tokens:        StrLib.TArrayOfStr;
  LodName:       string;

begin
  ImageSettings := PPCHAR(Context.EBP + EBP_ARG_IMAGE_TEMPLATE)^;
  Tokens        := StrLib.Explode(ImageSettings, ';');

  if
    (Length(Tokens) >= MIN_NUM_TOKENS)  and
    (FindFileLod(Tokens[TOKEN_DEFNAME], LodName))
  then begin
    Tokens[TOKEN_LODNAME] := SysUtils.ExtractFileName(LodName);
    ZvsLibImageTemplate   := StrLib.Join(Tokens, ';');
    PPCHAR(Context.EBP + EBP_ARG_IMAGE_TEMPLATE)^ :=  pchar(ZvsLibImageTemplate);
  end;

  //fatalerror(PPCHAR(Context.EBP + EBP_ARG_IMAGE_TEMPLATE)^);

  result  :=  Core.EXEC_DEF_CODE;
end; // .function Hook_ZvsLib_ExtractDef

function Hook_ZvsLib_ExtractDef_GetGamePath (Context: Core.PHookContext): LONGBOOL; stdcall;
const
  EBP_LOCAL_GAME_PATH = 16;

begin
  ZvsLibGamePath  := SysUtils.ExtractFileDir(ParamStr(0));
  {!} Assert(Length(ZvsLibGamePath) > 0);
  // Increase string ref count for C++ Builder AnsiString
  Inc(pinteger(Utils.PtrOfs(pointer(ZvsLibGamePath), -8))^);

  PPCHAR(Context.EBP - EBP_LOCAL_GAME_PATH)^ :=  pchar(ZvsLibGamePath);
  Context.RetAddr := Utils.PtrOfs(Context.RetAddr, 486);
  result          := not Core.EXEC_DEF_CODE;
end; // .function Hook_ZvsLib_ExtractDef_GetGamePath

function Hook_ZvsPlaceMapObject (Hook: PatchApi.THiHook; x, y, Level, ObjType, ObjSubtype, ObjType2, ObjSubtype2, Terrain: integer): integer; stdcall;
begin
  if IsLocalPlaceObject then begin
    Erm.FireRemoteErmEvent(Erm.TRIGGER_ONREMOTEEVENT, [Erm.REMOTE_EVENT_PLACE_OBJECT, x, y, Level, ObjType, ObjSubtype, ObjType2, ObjSubtype2, Terrain]);
  end;

  result := PatchApi.Call(PatchApi.CDECL_, Hook.GetOriginalFunc(), [x, y, Level, ObjType, ObjSubtype, ObjType2, ObjSubtype2, Terrain]);
end;

procedure OnRemoteMapObjectPlace (Event: GameExt.PEvent); stdcall;
begin
  // Switch Network event
  case Erm.x[1] of
    Erm.REMOTE_EVENT_PLACE_OBJECT: begin
      IsLocalPlaceObject := false;
      Erm.ZvsPlaceMapObject(Erm.x[2], Erm.x[3], Erm.x[4], Erm.x[5], Erm.x[6], Erm.x[7], Erm.x[8], Erm.x[9]);
      IsLocalPlaceObject := true;
    end;
  end;
end; // .procedure OnRemoteMapObjectPlace

function Hook_ZvsEnter2Monster (Context: Core.PHookContext): LONGBOOL; stdcall;
const
  ARG_MAP_ITEM  = 8;
  ARG_MIXED_POS = 16;

var
  x, y, z:  integer;
  MixedPos: integer;
  MapItem:  pointer;

begin
  MapItem  := ppointer(Context.EBP + ARG_MAP_ITEM)^;
  MapItemToCoords(MapItem, x, y, z);
  MixedPos := CoordsToMixedPos(x, y, z);
  pinteger(Context.EBP + ARG_MIXED_POS)^ := MixedPos;

  Context.RetAddr := Ptr($7577B2);
  result          := not Core.EXEC_DEF_CODE;
end; // .function Hook_ZvsEnter2Monster

function Hook_ZvsEnter2Monster2 (Context: Core.PHookContext): LONGBOOL; stdcall;
const
  ARG_MAP_ITEM  = 8;
  ARG_MIXED_POS = 16;

var
  x, y, z:  integer;
  MixedPos: integer;
  MapItem:  pointer;

begin
  MapItem  := ppointer(Context.EBP + ARG_MAP_ITEM)^;
  MapItemToCoords(MapItem, x, y, z);
  MixedPos := CoordsToMixedPos(x, y, z);
  pinteger(Context.EBP + ARG_MIXED_POS)^ := MixedPos;

  Context.RetAddr := Ptr($757A87);
  result          := not Core.EXEC_DEF_CODE;
end; // .function Hook_ZvsEnter2Monster2

function Hook_OnBeforeBattlefieldVisible (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  HadTacticsPhase := false;
  CombatRound     := -1000000000;
  Erm.FireErmEvent(Erm.TRIGGER_ONBEFORE_BATTLEFIELD_VISIBLE);
  result := Core.EXEC_DEF_CODE;
end;

function Hook_OnBattlefieldVisible (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  HadTacticsPhase := Heroes.CombatManagerPtr^.IsTactics;

  if not HadTacticsPhase then begin
    CombatRound        := 0;
    pinteger($79F0B8)^ := 0;
    pinteger($79F0BC)^ := 0;
  end;

  Erm.FireErmEvent(Erm.TRIGGER_BATTLEFIELD_VISIBLE);
  Erm.v[997] := CombatRound;
  Erm.FireErmEventEx(Erm.TRIGGER_BR, [CombatRound]);

  result := true;
end; // .function Hook_OnBattlefieldVisible

function Hook_OnAfterTacticsPhase (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  Erm.FireErmEvent(Erm.TRIGGER_AFTER_TACTICS_PHASE);

  if HadTacticsPhase then begin
    CombatRound := 0;
    Erm.v[997]  := CombatRound;
    Erm.FireErmEvent(Erm.TRIGGER_BR);
  end;

  result := Core.EXEC_DEF_CODE;
end;

function Hook_OnCombatRound_Start (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  if pinteger($79F0B8)^ <> Heroes.CombatManagerPtr^.Round then begin
    Inc(CombatRound);
  end;

  result := Core.EXEC_DEF_CODE;
end;

function Hook_OnCombatRound_End (Context: Core.PHookContext): LONGBOOL; stdcall;
begin
  Erm.v[997] := CombatRound;
  Erm.FireErmEvent(Erm.TRIGGER_BR);
  result := Core.EXEC_DEF_CODE;
end;

var
  UseNativePrng: boolean = false;

function Hook_SRand (OrigFunc: pointer; Seed: integer): integer; stdcall;
begin
  if UseNativePrng then begin
    result := PatchApi.Call(THISCALL_, OrigFunc, [Seed]);
  end else begin
    RandMt.InitMt(Seed);
    result := 0;
  end;
end;

function Hook_Rand (OrigFunc: pointer; MinValue, MaxValue: integer): integer; stdcall;
begin
  if UseNativePrng then begin
    result := PatchApi.Call(FASTCALL_, OrigFunc, [MinValue, MaxValue]);
  end else begin
    result := RandMt.RandomRangeMt(MinValue, MaxValue);
  end;
end;

procedure OnBeforeBattleUniversal (Event: GameExt.PEvent); stdcall;
begin
  UseNativePrng := true;
  CombatRound   := -1000000000;
end;

procedure OnBattleReplay (Event: GameExt.PEvent); stdcall;
begin
  OnBeforeBattleUniversal(Event);
  Erm.FireErmEvent(TRIGGER_BATTLE_REPLAY);
end;

procedure OnBeforeBattleReplay (Event: GameExt.PEvent); stdcall;
begin
  Erm.FireErmEvent(TRIGGER_BEFORE_BATTLE_REPLAY);
end;

procedure OnBattlefieldVisible (Event: GameExt.PEvent); stdcall;
begin
  if Heroes.IsLocalGame then begin
    UseNativePrng := false;
  end;
end;

procedure OnAfterBattleUniversal (Event: GameExt.PEvent); stdcall;
begin
  UseNativePrng := false;
end;

procedure OnSavegameWrite (Event: PEvent); stdcall;
var
  RngState: RandMt.TRngState;

begin
  RngState := RandMt.GetState;

  with Stores.NewRider(RNG_SAVE_SECTION) do begin
    WriteInt(Length(RngState));
    Write(Length(RngState), @RngState[0]);
  end;

  RandMt.SetState(RngState);
end;

procedure OnSavegameRead (Event: PEvent); stdcall;
var
  RngState: RandMt.TRngState;

begin
  with Stores.NewRider(RNG_SAVE_SECTION) do begin
    SetLength(RngState, ReadInt);

    if RngState <> nil then begin
      Read(Length(RngState), @RngState[0]);
      RandMt.SetState(RngState);
    end;
  end;
end;

function Hook_PostBattle_OnAddCreaturesExp (Context: ApiJack.PHookContext): longbool; stdcall;
var
  ExpToAdd: integer;
  FinalExp: integer;

begin
  // EAX: Old experience value
  // EBP - $C: addition
  ExpToAdd := pinteger(Context.EBP - $C)^;

  if ExpToAdd < 0 then begin
    ExpToAdd := High(integer);
  end;

  FinalExp := Math.Max(0, Context.EAX) + ExpToAdd;

  if FinalExp < 0 then begin
    FinalExp := High(integer);
  end;

  ppinteger(Context.EBP - 8)^^ := FinalExp;

  Context.RetAddr := Ptr($71922D);
  result          := false;
end; // .function Hook_PostBattle_OnAddCreaturesExp

function Hook_DisplayComplexDialog_GetTimeout (Context: ApiJack.PHookContext): longbool; stdcall;
var
  Opts:          integer;
  Timeout:       integer;
  MsgType:       integer;
  TextAlignment: integer;
  StrConfig:     integer;

begin
  Opts          := pinteger(Context.EBP + $10)^;
  Timeout       := Opts and $FFFF;
  StrConfig     := (Opts shr 24) and $FF;
  MsgType       := (Opts shr 16) and $0F;
  TextAlignment := ((Opts shr 20) and $0F) - 1;

  if MsgType = 0 then begin
    MsgType := ord(Heroes.MES_MES);
  end;

  if TextAlignment < 0 then begin
    TextAlignment := Heroes.TEXT_ALIGN_CENTER;
  end;

  Erm.SetDialog8TextAlignment(TextAlignment);

  pinteger(Context.EBP - $24)^ := Timeout;
  pinteger(Context.EBP - $2C)^ := MsgType;
  pbyte(Context.EBP - $2C0)^   := StrConfig;
  result                       := true;
end; // .function Hook_DisplayComplexDialog_GetTimeout

function Hook_ShowParsedDlg8Items_CreateTextField (Context: ApiJack.PHookContext): longbool; stdcall;
begin
  pinteger(Context.EBP - 132)^ := GetDialog8TextAlignment();
  result := true;
end;

function Hook_ShowParsedDlg8Items_Init (Context: ApiJack.PHookContext): longbool; stdcall;
begin
  // WoG Native Dialogs uses imported function currently and manually determines selected item
  // Heroes.ComplexDlgResItemId^ := Erm.GetPreselectedDialog8ItemId();
  result := true;
end;

function Hook_ZvsDisplay8Dialog_BeforeShow (Context: ApiJack.PHookContext): longbool; stdcall;
begin
  Context.EAX     := DisplayComplexDialog(ppointer(Context.EBP + $8)^, Ptr($8403BC), Heroes.TMesType(pinteger(Context.EBP + $10)^),
                                          pinteger(Context.EBP + $14)^);
  result          := false;
  Context.RetAddr := Ptr($716A04);
end;

const
  PARSE_PICTURE_VAR_SHOW_ZERO_QUANTITIES = -$C0;

function Hook_ParsePicture_Start (Context: ApiJack.PHookContext): longbool; stdcall;
const
  PIC_TYPE_ARG = +$8;

var
  PicType: integer;

begin
  PicType := pinteger(Context.EBP + PIC_TYPE_ARG)^;

  if PicType <> -1 then begin
    pinteger(Context.EBP + PARSE_PICTURE_VAR_SHOW_ZERO_QUANTITIES)^ := PicType shr 31;
    pinteger(Context.EBP + PIC_TYPE_ARG)^                           := PicType and not (1 shl 31);
  end else begin
    pinteger(Context.EBP + PARSE_PICTURE_VAR_SHOW_ZERO_QUANTITIES)^ := 0;
  end;

  (* Not ideal but still solution. Apply runtime patches to allow/disallow displaying of zero quantities *)
  if pinteger(Context.EBP + PARSE_PICTURE_VAR_SHOW_ZERO_QUANTITIES)^ <> 0 then begin
    pbyte($4F55EC)^ := $7C;   // resources
    pbyte($4F5EB3)^ := $EB;   // experience
    pword($4F5BCA)^ := $9090; // monsters
    pbyte($4F5ACC)^ := $EB;   // primary skills
    pbyte($4F5725)^ := $7C;   // money
    pbyte($4F5765)^ := $EB;   // money
  end else begin
    pbyte($4F55EC)^ := $7E;   // resources
    pbyte($4F5EB3)^ := $75;   // experience
    pword($4F5BCA)^ := $7A74; // monsters
    pbyte($4F5ACC)^ := $75;   // primary skills
    pbyte($4F5725)^ := $7E;   // money
    pbyte($4F5765)^ := $75;   // money
  end;

  result := true;
end; // .function Hook_ParsePicture_Start

function Hook_HDlg_BuildPcx (OrigFunc: pointer; x, y, dx, dy, ItemId: integer; PcxFile: pchar; Flags: integer): pointer; stdcall;
const
  DLG_ITEM_STRUCT_SIZE = 52;

var
  FileName:       string;
  FileExt:        string;
  PcxConstructor: pointer;

begin
  FileName       := PcxFile;
  FileExt        := SysUtils.AnsiLowerCase(StrLib.ExtractExt(FileName));
  PcxConstructor := Ptr($44FFA0);

  if FileExt = 'pcx16' then begin
    FileName       := SysUtils.ChangeFileExt(FileName, '') + '.pcx';
    PcxConstructor := Ptr($450340);
  end;

  result := Ptr(PatchApi.Call(THISCALL_, PcxConstructor, [Heroes.MAlloc(DLG_ITEM_STRUCT_SIZE), x, y, dx, dy, ItemId, pchar(FileName), Flags]));
end;

function Hook_HandleMonsterCast_End (Context: ApiJack.PHookContext): longbool; stdcall;
const
  CASTER_MON         = 1;
  NO_EXT_TARGET_POS  = -1;

  FIELD_ACTIVE_SPELL = $4E0;
  FIELD_NUM_MONS     = $4C;
  FIELD_MON_ID       = $34;

  MON_FAERIE_DRAGON   = 134;
  MON_SANTA_GREMLIN   = 173;
  MON_COMMANDER_FIRST = 174;
  MON_COMMANDER_LAST  = 191;

  WOG_GET_NPC_MAGIC_POWER = $76BEEA;

var
  Spell:      integer;
  TargetPos:  integer;
  Stack:      pointer;
  MonId:      integer;
  NumMons:    integer;
  SkillLevel: integer;
  SpellPower: integer;

begin
  TargetPos  := pinteger(Context.EBP + $8)^;
  Stack      := Ptr(Context.ESI);
  MonId      := pinteger(integer(Stack) + FIELD_MON_ID)^;
  Spell      := pinteger(integer(Stack) + FIELD_ACTIVE_SPELL)^;
  NumMons    := pinteger(integer(Stack) + FIELD_NUM_MONS)^;
  SpellPower := NumMons;
  SkillLevel := 2;

  if (TargetPos >= 0) and (TargetPos < 187) then begin
    if MonId = MON_FAERIE_DRAGON then begin
      SpellPower := NumMons * 5;
    end else if MonId = MON_SANTA_GREMLIN then begin
      SkillLevel := 0;
      SpellPower := (NumMons - 1) div 2;

      if (((NumMons - 1) and 1) <> 0) and (ZvsRandom(0, 1) = 1) then begin
        Inc(SpellPower);
      end;
    end else if Math.InRange(MonId, MON_COMMANDER_FIRST, MON_COMMANDER_LAST) then begin
      SpellPower := PatchApi.Call(CDECL_, Ptr(WOG_GET_NPC_MAGIC_POWER), [Stack]);
    end;

    Context.EAX := PatchApi.Call(THISCALL_, Ptr($5A0140), [Heroes.CombatManagerPtr^, Spell, TargetPos, CASTER_MON, NO_EXT_TARGET_POS, SkillLevel, SpellPower]);
  end;

  result          := false;
  Context.RetAddr := Ptr($4483DD);
end; // .function Hook_HandleMonsterCast_End

function Hook_ErmDlgFunctionActionSwitch (Context: ApiJack.PHookContext): longbool; stdcall;
const
  ARG_DLG_ID = 1;

  DLG_MOUSE_EVENT_INFO_VAR       = $887654;
  DLG_USER_COMMAND_VAR           = $887658;
  DLG_BODY_VAR                   = -$5C;
  DLG_BODY_ID_FIELD              = 200;
  DLG_COMMAND_CLOSE              = 1;
  DLG_ACTION_HOVER               = 4;
  DLG_ACTION_INDLG_CLICK         = 512;
  DLG_ACTION_SCROLL_WHEEL        = 522;
  DLG_ACTION_KEY_PRESSED         = 256;
  DLG_ACTION_OUTDLG_LMB_PRESSED  = 8;
  DLG_ACTION_OUTDLG_LMB_RELEASED = 16;
  DLG_ACTION_OUTDLG_RMB_PRESSED  = 32;
  DLG_ACTION_OUTDLG_RMB_RELEASED = 64;
  DLG_ACTION_OUTDLG_CLICK        = 8;
  MOUSE_OK_CLICK                 = 10;
  MOUSE_LMB_PRESSED              = 12;
  MOUSE_LMB_RELEASED             = 13;
  MOUSE_RMB_PRESSED              = 14;
  ACTION_KEY_PRESSED             = 20;
  ITEM_INSIDE_DLG                = -1;
  ITEM_OUTSIDE_DLG               = -2;

var
  MouseEventInfo: Heroes.PMouseEventInfo;
  SavedEventX:    integer;
  SavedEventY:    integer;
  SavedEventZ:    integer;

begin
  MouseEventInfo := ppointer(Context.EBP + $8)^;
  result         := false;

  case MouseEventInfo.ActionType of
    DLG_ACTION_INDLG_CLICK:  begin end;
    DLG_ACTION_SCROLL_WHEEL: begin MouseEventInfo.Item := ITEM_INSIDE_DLG; end;

    DLG_ACTION_KEY_PRESSED: begin
      MouseEventInfo.Item := ITEM_INSIDE_DLG;
    end;

    DLG_ACTION_OUTDLG_RMB_PRESSED: begin
      MouseEventInfo.Item          := ITEM_OUTSIDE_DLG;
      MouseEventInfo.ActionSubtype := MOUSE_RMB_PRESSED;
    end;

    DLG_ACTION_OUTDLG_LMB_PRESSED: begin
      MouseEventInfo.Item          := ITEM_OUTSIDE_DLG;
      MouseEventInfo.ActionSubtype := MOUSE_LMB_PRESSED;
    end;

    DLG_ACTION_OUTDLG_LMB_RELEASED: begin
      MouseEventInfo.Item          := ITEM_OUTSIDE_DLG;
      MouseEventInfo.ActionSubtype := MOUSE_LMB_RELEASED;
    end;
  else
    result := true;
  end; // .switch MouseEventInfo.ActionType

  if result then begin
    exit;
  end;

  ppointer(DLG_MOUSE_EVENT_INFO_VAR)^ := MouseEventInfo;
  pinteger(DLG_USER_COMMAND_VAR)^     := 0;

  SavedEventX := Erm.ZvsEventX^;
  SavedEventY := Erm.ZvsEventY^;
  SavedEventZ := Erm.ZvsEventZ^;

  Erm.ArgXVars[ARG_DLG_ID] := pinteger(pinteger(Context.EBP + DLG_BODY_VAR)^ + DLG_BODY_ID_FIELD)^;

  Erm.ZvsEventX^ := Erm.ArgXVars[ARG_DLG_ID];
  Erm.ZvsEventY^ := MouseEventInfo.Item;
  Erm.ZvsEventZ^ := MouseEventInfo.ActionSubtype;

  Erm.FireMouseEvent(Erm.TRIGGER_DL, MouseEventInfo);

  Erm.ZvsEventX^ := SavedEventX;
  Erm.ZvsEventY^ := SavedEventY;
  Erm.ZvsEventZ^ := SavedEventZ;

  Context.EAX := 1;
  ppointer(DLG_MOUSE_EVENT_INFO_VAR)^ := nil;

  if pinteger(DLG_USER_COMMAND_VAR)^ = DLG_COMMAND_CLOSE then begin
    Context.EAX                  := 2;
    MouseEventInfo.ActionType    := DLG_ACTION_INDLG_CLICK;
    MouseEventInfo.ActionSubtype := MOUSE_OK_CLICK;

    // Assign result item
    pinteger(pinteger(Context.EBP - $10)^ + 56)^ := MouseEventInfo.Item;
  end;

  result          := false;
  Context.RetAddr := Ptr($7297C6);
end; // .function Hook_ErmDlgFunctionActionSwitch

procedure DumpWinPeModuleList;
const
  DEBUG_WINPE_MODULE_LIST_PATH = GameExt.DEBUG_DIR + '\pe modules.txt';

var
  i: integer;

begin
  {!} Core.ModuleContext.Lock;
  Core.ModuleContext.UpdateModuleList;

  with FilesEx.WriteFormattedOutput(GameExt.GameDir + '\' + DEBUG_WINPE_MODULE_LIST_PATH) do begin
    Line('> Win32 executable modules');
    EmptyLine;

    for i := 0 to Core.ModuleContext.ModuleList.Count - 1 do begin
      Line(Core.ModuleContext.ModuleInfo[i].ToStr);
    end;
  end;

  {!} Core.ModuleContext.Unlock;
end; // .procedure DumpWinPeModuleList

procedure DumpExceptionContext (ExcRec: PExceptionRecord; Context: Windows.PContext);
const
  DEBUG_EXCEPTION_CONTEXT_PATH = GameExt.DEBUG_DIR + '\exception context.txt';

var
  ExceptionText: string;
  LineText:      string;
  Ebp:           integer;
  Esp:           integer;
  RetAddr:       integer;
  i:             integer;

begin
  {!} Core.ModuleContext.Lock;
  Core.ModuleContext.UpdateModuleList;

  with FilesEx.WriteFormattedOutput(GameExt.GameDir + '\' + DEBUG_EXCEPTION_CONTEXT_PATH) do begin
    case ExcRec.ExceptionCode of
      $C0000005: begin
        if ExcRec.ExceptionInformation[0] <> 0 then begin
          ExceptionText := 'Failed to write data at ' + Format('%x', [integer(ExcRec.ExceptionInformation[1])]);
        end else begin
          ExceptionText := 'Failed to read data at ' + Format('%x', [integer(ExcRec.ExceptionInformation[1])]);
        end;
      end; // .case $C0000005

      $C000008C: ExceptionText := 'Array index is out of bounds';
      $80000003: ExceptionText := 'Breakpoint encountered';
      $80000002: ExceptionText := 'Data access misalignment';
      $C000008D: ExceptionText := 'One of the operands in a floating-point operation is denormal';
      $C000008E: ExceptionText := 'Attempt to divide a floating-point value by a floating-point divisor of zero';
      $C000008F: ExceptionText := 'The result of a floating-point operation cannot be represented exactly as a decimal fraction';
      $C0000090: ExceptionText := 'Invalid floating-point exception';
      $C0000091: ExceptionText := 'The exponent of a floating-point operation is greater than the magnitude allowed by the corresponding type';
      $C0000092: ExceptionText := 'The stack overflowed or underflowed as the result of a floating-point operation';
      $C0000093: ExceptionText := 'The exponent of a floating-point operation is less than the magnitude allowed by the corresponding type';
      $C000001D: ExceptionText := 'Attempt to execute an illegal instruction';
      $C0000006: ExceptionText := 'Attempt to access a page that was not present, and the system was unable to load the page';
      $C0000094: ExceptionText := 'Attempt to divide an integer value by an integer divisor of zero';
      $C0000095: ExceptionText := 'Integer arithmetic overflow';
      $C0000026: ExceptionText := 'An invalid exception disposition was returned by an exception handler';
      $C0000025: ExceptionText := 'Attempt to continue from an exception that isn''t continuable';
      $C0000096: ExceptionText := 'Attempt to execute a privilaged instruction.';
      $80000004: ExceptionText := 'Single step exception';
      $C00000FD: ExceptionText := 'Stack overflow';
      else       ExceptionText := 'Unknown exception';
    end; // .switch ExcRec.ExceptionCode

    Line(ExceptionText + '.');
    Line(Format('EIP: %s. Code: %x', [Core.ModuleContext.AddrToStr(Ptr(Context.Eip)), ExcRec.ExceptionCode]));
    EmptyLine;
    Line('> Registers');

    Line('EAX: ' + Core.ModuleContext.AddrToStr(Ptr(Context.Eax), Core.ANALYZE_DATA));
    Line('ECX: ' + Core.ModuleContext.AddrToStr(Ptr(Context.Ecx), Core.ANALYZE_DATA));
    Line('EDC: ' + Core.ModuleContext.AddrToStr(Ptr(Context.Edx), Core.ANALYZE_DATA));
    Line('EBX: ' + Core.ModuleContext.AddrToStr(Ptr(Context.Ebx), Core.ANALYZE_DATA));
    Line('ESP: ' + Core.ModuleContext.AddrToStr(Ptr(Context.Esp), Core.ANALYZE_DATA));
    Line('EBP: ' + Core.ModuleContext.AddrToStr(Ptr(Context.Ebp), Core.ANALYZE_DATA));
    Line('ESI: ' + Core.ModuleContext.AddrToStr(Ptr(Context.Esi), Core.ANALYZE_DATA));
    Line('EDI: ' + Core.ModuleContext.AddrToStr(Ptr(Context.Edi), Core.ANALYZE_DATA));

    EmptyLine;
    Line('> Callstack');
    Ebp     := Context.Ebp;
    RetAddr := 1;

    try
      while (Ebp <> 0) and (RetAddr <> 0) do begin
        RetAddr := pinteger(Ebp + 4)^;

        if RetAddr <> 0 then begin
          Line(Core.ModuleContext.AddrToStr(Ptr(RetAddr)));
          Ebp := pinteger(Ebp)^;
        end;
      end;
    except
      // Stop processing callstack
    end; // .try

    EmptyLine;
    Line('> Stack');
    Esp := Context.Esp - sizeof(integer) * 5;

    try
      for i := 1 to 40 do begin
        LineText := IntToHex(Esp, 8);

        if Esp = integer(Context.Esp) then begin
          LineText := LineText + '*';
        end;

        LineText := LineText + ': ' + Core.ModuleContext.AddrToStr(ppointer(Esp)^, Core.ANALYZE_DATA);
        Inc(Esp, sizeof(integer));
        Line(LineText);
      end; // .for
    except
      // Stop stack traversing
    end; // .try
  end; // .with

  {!} Core.ModuleContext.Unlock;
end; // .procedure DumpExceptionContext

function TopLevelExceptionHandler (const ExceptionPtrs: TExceptionPointers): integer; stdcall;
const
  EXCEPTION_CONTINUE_SEARCH = 0;

begin
  DumpExceptionContext(ExceptionPtrs.ExceptionRecord, ExceptionPtrs.ContextRecord);
  EventMan.GetInstance.Fire('OnGenerateDebugInfo');
  DlgMes.Msg('Game crashed. All debug information is inside ' + DEBUG_DIR + ' subfolder');

  result := EXCEPTION_CONTINUE_SEARCH;
end; // .function TopLevelExceptionHandler

function OnUnhandledException (const ExceptionPtrs: TExceptionPointers): integer; stdcall;
type
  THandler = function (const ExceptionPtrs: TExceptionPointers): integer; stdcall;

const
  EXCEPTION_CONTINUE_SEARCH = 0;

var
  i: integer;

begin
  {!} ExceptionsCritSection.Enter;

  for i := 0 to TopLevelExceptionHandlers.Count - 1 do begin
    THandler(TopLevelExceptionHandlers[i])(ExceptionPtrs);
  end;

  {!} ExceptionsCritSection.Leave;

  result := EXCEPTION_CONTINUE_SEARCH;
end; // .function OnUnhandledException

function Hook_SetUnhandledExceptionFilter (Context: Core.PHookContext): longbool; stdcall;
var
{Un} NewHandler: pointer;

begin
  NewHandler := ppointer(Context.ESP + 8)^;
  // * * * * * //
  if (NewHandler <> nil) and ((cardinal(NewHandler) < $401000) or (cardinal(NewHandler) > $7845FA)) then begin
    {!} ExceptionsCritSection.Enter;
    TopLevelExceptionHandlers.Add(NewHandler);
    {!} ExceptionsCritSection.Leave;
  end;

  (* result = nil *)
  Context.EAX := 0;

  (* return to calling routine *)
  Context.RetAddr := Core.Ret(1);

  result := Core.IGNORE_DEF_CODE;
end; // .function Hook_SetUnhandledExceptionFilter

procedure OnGenerateDebugInfo (Event: PEvent); stdcall;
begin
  DumpWinPeModuleList;
end;

procedure OnAfterWoG (Event: GameExt.PEvent); stdcall;
const
  ZVSLIB_EXTRACTDEF_OFS             = 100668;
  ZVSLIB_EXTRACTDEF_GETGAMEPATH_OFS = 260;

  NOP7: string  = #$90#$90#$90#$90#$90#$90#$90;

var
  Zvslib1Handle:  integer;
  Addr:           integer;
  NewAddr:        pointer;
  MinTimerResol:  cardinal;
  MaxTimerResol:  cardinal;
  CurrTimerResol: cardinal;

begin
  (* Ini handling *)
  Core.Hook(@Hook_ReadStrIni, Core.HOOKTYPE_JUMP, 5, ZvsReadStrIni);
  Core.Hook(@Hook_WriteStrIni, Core.HOOKTYPE_JUMP, 5, ZvsWriteStrIni);
  Core.Hook(@Hook_WriteIntIni, Core.HOOKTYPE_JUMP, 5, ZvsWriteIntIni);

  (* DL dialogs centering *)
  Core.Hook(@Hook_ZvsGetWindowWidth, Core.HOOKTYPE_BRIDGE, 5, Ptr($729C5A));
  Core.Hook(@Hook_ZvsGetWindowHeight, Core.HOOKTYPE_BRIDGE, 5, Ptr($729C6D));

  (* Mark the freshest savegame *)
  MarkFreshestSavegame;

  (* Fix multi-thread CPU problem *)
  if UseOnlyOneCpuCoreOpt then begin
    Windows.SetProcessAffinityMask(Windows.GetCurrentProcess, 1);
  end;

  (* Fix HotSeat second hero name *)
  Core.Hook(@Hook_SetHotseatHeroName, Core.HOOKTYPE_BRIDGE, 6, Ptr($5125B0));
  Core.WriteAtCode(Length(NOP7), pointer(NOP7), Ptr($5125F9));

  (* Universal CPU patch *)
  if CpuTargetLevel < 100 then begin
    // Try to set timer resolution to at least 1ms = 10000 ns
    if (WinNative.NtQueryTimerResolution(MinTimerResol, MaxTimerResol, CurrTimerResol) = STATUS_SUCCESS) and (CurrTimerResol > 10000) and (MaxTimerResol < CurrTimerResol) then begin
      WinNative.NtSetTimerResolution(Math.Max(10000, MaxTimerResol), true, CurrTimerResol);
    end;

    hTimerEvent := Windows.CreateEvent(nil, true, false, nil);
    Core.ApiHook(@Hook_PeekMessageA, Core.HOOKTYPE_BRIDGE, Windows.GetProcAddress(GetModuleHandle('user32.dll'), 'PeekMessageA'));
  end;

  (* Remove duplicate ResetAll call *)
  pinteger($7055BF)^ :=  integer($90909090);
  PBYTE($7055C3)^    :=  $90;

  (* Optimize zvslib1.dll ini handling *)
  Zvslib1Handle   :=  Windows.GetModuleHandle('zvslib1.dll');
  Addr            :=  Zvslib1Handle + 1666469;
  Addr            :=  pinteger(Addr + pinteger(Addr)^ + 6)^;
  NewAddr         :=  @New_Zvslib_GetPrivateProfileStringA;
  Core.WriteAtCode(sizeof(NewAddr), @NewAddr, pointer(Addr));

  (* Redirect reading/writing game settings to ini *)
  // No saving settings after reading them
  PBYTE($50B964)^    := $C3;
  pinteger($50B965)^ := integer($90909090);

  ppointer($50B920)^ := Ptr(integer(@ReadGameSettings) - $50B924);
  ppointer($50BA2F)^ := Ptr(integer(@WriteGameSettings) - $50BA33);
  ppointer($50C371)^ := Ptr(integer(@WriteGameSettings) - $50C375);

  (* Fix game version to enable map generator *)
  Heroes.GameVersion^ :=  Heroes.SOD_AND_AB;

  (* Fix gethostbyname function to return external IP address at first place *)
  if FixGetHostByNameOpt then begin
    Core.p.WriteHiHook
    (
      Windows.GetProcAddress(Windows.GetModuleHandle('ws2_32.dll'), 'gethostbyname'),
      PatchApi.SPLICE_,
      PatchApi.EXTENDED_,
      PatchApi.STDCALL_,
      @Hook_GetHostByName
    );
  end;

  (* Fix ApplyDamage calls, so that !?MF1 damage is displayed correctly in log *)
  Core.ApiHook(@Hook_ApplyDamage_Ebx_Local7,  Core.HOOKTYPE_BRIDGE, Ptr($43F95B + 5));
  Core.ApiHook(@Hook_ApplyDamage_Ebx,         Core.HOOKTYPE_BRIDGE, Ptr($43FA5E + 5));
  Core.ApiHook(@Hook_ApplyDamage_Local7,      Core.HOOKTYPE_BRIDGE, Ptr($43FD3D + 5));
  Core.ApiHook(@Hook_ApplyDamage_Ebx,         Core.HOOKTYPE_BRIDGE, Ptr($4400DF + 5));
  Core.ApiHook(@Hook_ApplyDamage_Esi_Arg1,    Core.HOOKTYPE_BRIDGE, Ptr($440858 + 5));
  Core.ApiHook(@Hook_ApplyDamage_Ebx,         Core.HOOKTYPE_BRIDGE, Ptr($440E70 + 5));
  Core.ApiHook(@Hook_ApplyDamage_Arg1,        Core.HOOKTYPE_BRIDGE, Ptr($441048 + 5));
  Core.ApiHook(@Hook_ApplyDamage_Esi,         Core.HOOKTYPE_BRIDGE, Ptr($44124C + 5));
  Core.ApiHook(@Hook_ApplyDamage_Local4,      Core.HOOKTYPE_BRIDGE, Ptr($441739 + 5));
  Core.ApiHook(@Hook_ApplyDamage_Local8,      Core.HOOKTYPE_BRIDGE, Ptr($44178A + 5));
  Core.ApiHook(@Hook_ApplyDamage_Arg1,        Core.HOOKTYPE_BRIDGE, Ptr($46595F + 5));
  Core.ApiHook(@Hook_ApplyDamage_Ebx,         Core.HOOKTYPE_BRIDGE, Ptr($469A93 + 5));
  Core.ApiHook(@Hook_ApplyDamage_Local13,     Core.HOOKTYPE_BRIDGE, Ptr($5A1065 + 5));

  (* Fix negative offsets handling in fonts *)
  Core.p.WriteDataPatch(Ptr($4B534A), ['B6']);
  Core.p.WriteDataPatch(Ptr($4B53E6), ['B6']);

  (* Fix WoG/ERM versions *)
  Core.Hook(@Hook_GetWoGAndErmVersions, Core.HOOKTYPE_BRIDGE, 14, Ptr($73226C));

  (*  Fix zvslib1.dll ExtractDef function to support mods  *)
  Core.ApiHook
  (
    @Hook_ZvsLib_ExtractDef, Core.HOOKTYPE_BRIDGE, Ptr(Zvslib1Handle + ZVSLIB_EXTRACTDEF_OFS + 3)
  );

  Core.ApiHook
  (
    @Hook_ZvsLib_ExtractDef_GetGamePath,
    Core.HOOKTYPE_BRIDGE,
    Ptr(Zvslib1Handle + ZVSLIB_EXTRACTDEF_OFS + ZVSLIB_EXTRACTDEF_GETGAMEPATH_OFS)
  );

  Core.p.WriteHiHook(Ptr($71299E), PatchApi.SPLICE_, PatchApi.EXTENDED_, PatchApi.CDECL_, @Hook_ZvsPlaceMapObject);

  (* Syncronise object creation at local and remote PC *)
  EventMan.GetInstance.On('OnTrigger ' + IntToStr(Erm.TRIGGER_ONREMOTEEVENT), OnRemoteMapObjectPlace);

  (* Fixed bug with combined artifact (# > 143) dismounting in heroes meeting screen *)
  Core.p.WriteDataPatch(Ptr($4DC358), ['A0']);

  (* Fix WoG bug: do not rely on MixedPos argument for Enter2Monster(2), get coords from map object instead
     EDIT: no need anymore, fixed MixedPos *)
  if FALSE then begin
    Core.Hook(@Hook_ZvsEnter2Monster,  Core.HOOKTYPE_BRIDGE, 19, Ptr($75779F));
    Core.Hook(@Hook_ZvsEnter2Monster2, Core.HOOKTYPE_BRIDGE, 19, Ptr($757A74));
  end;

  (* Fix MixedPos to not drop higher order bits and not treat them as underground flag *)
  Core.p.WriteDataPatch(Ptr($711F4F), ['8B451425FFFFFF048945149090909090909090']);

  (* Fix WoG bug: double !?OB54 event generation when attacking without moving due to Enter2Object + Enter2Monster2 calling *)
  Core.p.WriteDataPatch(Ptr($757AA0), ['EB2C90909090']);

  (* Fix battle round counting: no !?BR before battlefield is shown, -1000000000 incrementing for the whole tactics phase, the
     first real round always starts from 0 *)
  Core.ApiHook(@Hook_OnBeforeBattlefieldVisible, Core.HOOKTYPE_BRIDGE, Ptr($75EAEA));
  Core.ApiHook(@Hook_OnBattlefieldVisible,       Core.HOOKTYPE_BRIDGE, Ptr($462E2B));
  Core.ApiHook(@Hook_OnAfterTacticsPhase,        Core.HOOKTYPE_BRIDGE, Ptr($75D137));
  Core.ApiHook(@Hook_OnCombatRound_Start,        Core.HOOKTYPE_BRIDGE, Ptr($76065B));
  Core.ApiHook(@Hook_OnCombatRound_End,          Core.HOOKTYPE_BRIDGE, Ptr($7609A3));
  // Disable BACall2 function, generating !?BR event, because !?BR will be the same as OnCombatRound now
  Core.p.WriteDataPatch(Ptr($74D1AB), ['C3']);

  // Disable WoG AppearAfterTactics hook. We will call BR0 manually a bit after to reduce crashing probability
  Core.p.WriteDataPatch(Ptr($462C19), ['E8F2051A00']);

  // Use CombatRound instead of combat manager field to summon creatures every nth turn via creature experience system
  Core.p.WriteDataPatch(Ptr($71DFBE), ['8B15 %d', @CombatRound]);

  // Restore Nagash and Jeddite specialties
  Core.p.WriteDataPatch(Ptr($753E0B), ['E9990000009090']); // PrepareSpecWoG => ignore new WoG settings
  Core.p.WriteDataPatch(Ptr($79C3D8), ['FFFFFFFF']);       // HeroSpecWoG[0].Ind = -1

  // Fix check for multiplayer in attack type selection dialog, causing wrong "This feature does not work in Human vs Human network baced battle" message
  Core.p.WriteDataPatch(Ptr($762604), ['C5']);

  // Fix creature experience overflow after battle
  ApiJack.HookCode(Ptr($719225), @Hook_PostBattle_OnAddCreaturesExp);

  // Fix DisplayComplexDialog to overload the last argument
  // closeTimeoutMsec is now TComplexDialogOpts
  //  16 bits for closeTimeoutMsec.
  //  4 bits for msgType (1 - ok, 2 - question, 4 - popup, etc), 0 is treated as 1.
  //  4 bits for text alignment + 1.
  //  8 bits for H3 string internal purposes (0 mostly).
  ApiJack.HookCode(Ptr($4F7D83), @Hook_DisplayComplexDialog_GetTimeout);
  // Nop dlg.closeTimeoutMsec := closeTimeoutMsec
  Core.p.WriteDataPatch(Ptr($4F7E19), ['909090']);
  // Nop dlg.msgType := MSG_TYPE_MES
  Core.p.WriteDataPatch(Ptr($4F7E4A), ['90909090909090']);

  (* Fix ShowParsedDlg8Items function to allow custom text alignment and preselected item *)
  ApiJack.HookCode(Ptr($4F72B5), @Hook_ShowParsedDlg8Items_CreateTextField);
  ApiJack.HookCode(Ptr($4F7136), @Hook_ShowParsedDlg8Items_Init);

  (* Fix ZvsDisplay8Dialog to 2 extra arguments (msgType, alignment) and return -1 or 0..7 for chosen picture or 0/1 for question *)
  ApiJack.HookCode(Ptr($7169EB), @Hook_ZvsDisplay8Dialog_BeforeShow);

  (* Patch ParsePicture function to allow "0 something" values in generic h3 dialogs *)
  // Allocate new local variables EBP - $0B4
  Core.p.WriteDataPatch(Ptr($4F555A), ['B4000000']);
  // Unpack highest bit of Type parameter as "display 0 quantities" flag into new local variable
  ApiJack.HookCode(Ptr($4F5564), @Hook_ParsePicture_Start);

  (* Fix WoG HDlg::BuildPcx to allow .pcx16 virtual file extension to load image as pcx16 *)
  ApiJack.StdSplice(Ptr($7287FB), @Hook_HDlg_BuildPcx, ApiJack.CONV_STDCALL, 7);

  (* Fix Santa-Gremlins *)
  // Remove WoG FairePower hook
  Core.p.WriteDataPatch(Ptr($44836D), ['8B464C8D0480']);
  // Add new FairePower hook
  ApiJack.HookCode(Ptr($44836D), @Hook_HandleMonsterCast_End);
  // Disable Santa's every day growth
  Core.p.WriteDataPatch(Ptr($760D6D), ['EB']);
  // Restore Santa's normal growth
  Core.p.WriteDataPatch(Ptr($760C56), ['909090909090']);
  // Disable Santa's gifts
  Core.p.WriteDataPatch(Ptr($75A964), ['9090']);

  (* Fix multiplayer crashes: disable orig/diff.dat generation, always send packed whole savegames *)
  Core.p.WriteDataPatch(Ptr($4CAE51), ['E86A5EFCFF']);       // Disable WoG BuildAllDiff hook
  Core.p.WriteDataPatch(Ptr($6067E2), ['E809000000']);       // Disable WoG GZ functions hooks
  Core.p.WriteDataPatch(Ptr($4D6FCC), ['E8AF001300']);       // ...
  Core.p.WriteDataPatch(Ptr($4D700D), ['E8DEFE1200']);       // ...
  Core.p.WriteDataPatch(Ptr($4CAF32), ['EB']);               // do not create orig.dat on send
  if false then Core.p.WriteDataPatch(Ptr($4CAF37), ['01']); // save orig.dat on send compressed
  Core.p.WriteDataPatch(Ptr($4CAD91), ['E99701000090']);     // do not perform savegame diffs
  Core.p.WriteDataPatch(Ptr($41A0D1), ['EB']);               // do not create orig.dat on receive
  if false then Core.p.WriteDataPatch(Ptr($41A0DC), ['01']); // save orig.dat on receive compressed
  Core.p.WriteDataPatch(Ptr($4CAD5A), ['31C040']);           // Always gzip the data to be sent
  Core.p.WriteDataPatch(Ptr($589EA4), ['EB10']);             // Do not create orig on first savegame receive from server

  (* Replace Heroes 3 PRNG with thread-safe Mersenne Twister, except of multiplayer battles *)
  ApiJack.StdSplice(Ptr($50C7B0), @Hook_SRand, ApiJack.CONV_THISCALL, 1);
  ApiJack.StdSplice(Ptr($50C7C0), @Hook_Rand, ApiJack.CONV_FASTCALL, 2);

  (* Allow to handle dialog outer clicks and provide full mouse info for event *)
  ApiJack.HookCode(Ptr($7295F1), @Hook_ErmDlgFunctionActionSwitch);
end; // .procedure OnAfterWoG

procedure OnAfterVfsInit (Event: GameExt.PEvent); stdcall;
begin
  (* Install global top-level exception filter *)
  Windows.SetErrorMode(SEM_NOGPFAULTERRORBOX);
  Windows.SetUnhandledExceptionFilter(@OnUnhandledException);
  Core.ApiHook(@Hook_SetUnhandledExceptionFilter, Core.HOOKTYPE_BRIDGE, Windows.GetProcAddress(Windows.LoadLibrary('kernel32.dll'), 'SetUnhandledExceptionFilter'));
  Windows.SetUnhandledExceptionFilter(@TopLevelExceptionHandler);
end;

begin
  Windows.InitializeCriticalSection(InetCriticalSection);
  ExceptionsCritSection.Init;
  TopLevelExceptionHandlers := DataLib.NewList(not Utils.OWNS_ITEMS);
  IsMainThread              := true;
  Mp3TriggerHandledEvent    := Windows.CreateEvent(nil, false, false, nil);

  EventMan.GetInstance.On('OnAfterVfsInit', OnAfterVfsInit);
  EventMan.GetInstance.On('OnAfterWoG', OnAfterWoG);
  EventMan.GetInstance.On('OnBeforeBattleUniversal', OnBeforeBattleUniversal);
  EventMan.GetInstance.On('OnBattleReplay', OnBattleReplay);
  EventMan.GetInstance.On('OnBeforeBattleReplay', OnBeforeBattleReplay);
  EventMan.GetInstance.On('OnBattlefieldVisible', OnBattlefieldVisible);
  EventMan.GetInstance.On('OnAfterBattleUniversal', OnAfterBattleUniversal);
  EventMan.GetInstance.On('OnGenerateDebugInfo', OnGenerateDebugInfo);

  if FALSE then begin
    (* Save RandMT state in saved games *)
    (* Makes game predictable. Disabled *)
    EventMan.GetInstance.On('OnSavegameWrite', OnSavegameWrite);
    EventMan.GetInstance.On('OnSavegameRead',  OnSavegameRead);
  end;
end.
