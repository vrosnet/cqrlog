unit fRbnMonitor;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, LResources, Forms, Controls, Graphics, Dialogs,
  ComCtrls, ActnList, StdCtrls, Grids, lNetComponents, lNet, lclType, RegExpr;

const
  C_MAX_ROWS = 1000; //max lines in the list of RBN spots


type
  TRbnSpot = record
    spotter : String[20];
    dxstn   : String[20];
    freq    : String[20];
    mode    : String[10];
    qsl     : String[2];
    dxinfo  : String[1];
    signal  : String[3];
  end;

type
  TOnShowSpotEvent = procedure(RbnSpot : TRbnSpot) of Object;

type
  TRbnThread = class(TThread)
  private
    cs  : TRTLCriticalSection;
    reg : TRegExpr;
    fRbnSpot : TRbnSpot;
    FOnShowSpot : TOnShowSpotEvent;
    function AllowedSpot(spotter, dxstn, freq, mode, LoTW, eQSL : String; var dxinfo : String) : Boolean;

    procedure ShowSpot;
  protected
    procedure Execute; override;
  public
    DxccWithLoTW              : Boolean;
    fil_SrcCont               : String;
    fil_IgnWkdHour            : Boolean;
    fil_IgnHourValue          : Integer;
    fil_IgnDate               : Boolean;
    fil_IgnDateValue          : String;
    fil_IgnTimeValue          : String;
    fil_AllowAllCall          : Boolean;
    fil_AllowOnlyCall         : Boolean;
    fil_AllowOnlyCallValue    : String;
    fil_AllowOnlyCallReg      : Boolean;
    fil_AllowOnlyCallRegValue : String;
    fil_AllowCont             : String;
    fil_AllowBands            : String;
    fil_AllowModes            : String;
    fil_AllowCnty             : String;
    fil_NotCnty               : String;
    fil_LoTWOnly              : Boolean;
    fil_eQSLOnly              : Boolean;
    fil_NewDXCOnly            : Boolean;

    property OnShowSpot : TOnShowSpotEvent read FOnShowSpot write FOnShowSpot;
end;


type

  { TfrmRbnMonitor }

  TfrmRbnMonitor = class(TForm)
    acRbnMonitor: TActionList;
    acConnect: TAction;
    acDisconnect: TAction;
    acFontSettings: TAction;
    acFilter: TAction;
    acRbnServer: TAction;
    acScrollDown : TAction;
    acHelp : TAction;
    btnEatFocus : TButton;
    dlgFont: TFontDialog;
    imgRbnMonitor: TImageList;
    sbRbn: TStatusBar;
    sgRbn: TStringGrid;
    ToolBar1: TToolBar;
    tbtnConnect: TToolButton;
    ToolButton1 : TToolButton;
    ToolButton2: TToolButton;
    ToolButton3: TToolButton;
    ToolButton4: TToolButton;
    ToolButton5: TToolButton;
    ToolButton6: TToolButton;
    ToolButton7: TToolButton;
    ToolButton8 : TToolButton;
    procedure acConnectExecute(Sender: TObject);
    procedure acDisconnectExecute(Sender: TObject);
    procedure acFilterExecute(Sender: TObject);
    procedure acFontSettingsExecute(Sender: TObject);
    procedure acHelpExecute(Sender : TObject);
    procedure acRbnServerExecute(Sender: TObject);
    procedure acScrollDownExecute(Sender : TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure sgRbnDblClick(Sender: TObject);
    procedure sgRbnDrawCell(Sender: TObject; aCol, aRow: Integer; aRect: TRect;
      aState: TGridDrawState);
    procedure sgRbnHeaderSized(Sender: TObject; IsColumn: Boolean;
      Index: Integer);
  private
    RbnMonThread : TRbnThread;
    lTelnet      : TLTelnetClientComponent;
    aRbnArchive  : Array of TRbnSpot;

    function  GetModeFromFreq(freq: string): string;

    procedure lConnect(aSocket: TLSocket);
    procedure lDisconnect(aSocket: TLSocket);
    procedure lReceive(aSocket: TLSocket);
    procedure AddSpotToThread(spot : String);

  public
    csRbnMonitor : TRTLCriticalSection;
    slRbnSpots   : TStringList;
    DeleteCount  : Integer;
    procedure SynRbnMonitor(RbnSpot : TRbnSpot);
    procedure LoadConfigToThread;
  end;

var
  frmRbnMonitor: TfrmRbnMonitor;

implementation

uses dUtils, uMyIni, dData, fRbnServer, dDXCluster, fRbnFilter, fNewQSO;

{ TfrmRbnMonitor }

procedure TRBNThread.ShowSpot;
begin
  if Assigned(OnShowSpot) then
  begin
    FOnShowSpot(fRbnSpot)
  end;
end;

function TRBNThread.AllowedSpot(spotter, dxstn, freq, mode, LoTW, eQSL : String; var dxinfo : String) : Boolean;
var
  SrcCont  : String;
  DestCont : String;
  Country  : String;
  waz,itu  : String;
  pfx      : String;
  LastDate : String;
  LastTime : String;
  Band     : String;
  adif     : Word;
  index    : Integer;
  f        : Double;
begin
  Result := False;

  dmDXCluster.id_country(spotter,now,pfx,Country,waz,itu,SrcCont);

  if (Pos(SrcCont+',',fil_SrcCont+',') = 0) and (fil_SrcCont<>'') then
  begin
    if dmData.DebugLevel>=2 then Writeln('RBNMonitor: ','Wrong source continent - ',SrcCont);
    exit
  end;

  if fil_IgnWkdHour then
  begin
    LastDate := FormatDateTime('YYY-MM-DD',now - (fil_IgnHourValue/57));
    LastTime := FormatDateTime('HH:NN',now - (fil_IgnHourValue/24))
  end
  else begin
    LastDate := fil_IgnDateValue;
    LastTime := fil_IgnTimeValue
  end;

  Band := dmDXCluster.GetBandFromFreq(freq,True);
  if (Band='') then
  begin
    if dmData.DebugLevel>=2 then Writeln('RBNMonitor: ','Wrong band - ',Band);
    exit
  end;

  if dmData.RbnCallExistsInLog(dxstn,Band,mode,LastDate,LastTime) then
  begin
    if dmData.DebugLevel>=2 then Writeln('RBNMonitor: ','Station already exist in the log - ',dxstn);
    exit
  end;

  if fil_AllowOnlyCall then
  begin
    if Pos(dxstn+',',fil_AllowOnlyCallValue+',') = 0 then
    begin
      if dmData.DebugLevel>=2 then Writeln('RBNMonitor: ','Station is not between allowed callsigns - ',dxstn);
      exit
    end
  end;

  if fil_AllowOnlyCallReg then
  begin
    reg.Expression  := fil_AllowOnlyCallRegValue;
    reg.InputString := dxstn;
    if not reg.Exec(1) then
    begin
      if dmData.DebugLevel>=2 then Writeln('RBNMonitor: ','Station is not between allowed callsigns - ',dxstn);
      exit
    end
  end;

  if (Pos(band+',',fil_AllowBands+',')=0) and (fil_AllowBands<>'') then
  begin
    if dmData.DebugLevel>=2 then Writeln('RBNMonitor: ','This band is NOT allowed - ',band);
    exit
  end;

  if (Pos(mode+',',fil_AllowModes+',')=0) and (fil_AllowModes<>'') then
  begin
    if dmData.DebugLevel>=2 then Writeln('RBNMonitor: ','This mode is NOT allowed - ',mode);
    exit
  end;

  adif := dmDXCluster.id_country(dxstn,now,Pfx,Country,waz,itu,DestCont);

  if (Pos(DestCont+',',fil_AllowCont+',') = 0) and (fil_AllowCont<>'') then
  begin
    if dmData.DebugLevel>=2 then Writeln('RBNMonitor: ','Wrong continent - ',DestCont);
    exit
  end;

  if ((fil_NotCnty<>'') and (Pos(pfx+',',fil_NotCnty+',')>0)) then
  begin
    if dmData.DebugLevel>=2 then Writeln('RBNMonitor: ','This country is not allowed - ',pfx);
    exit
  end;

  if ((fil_AllowCnty<>'') and (Pos(pfx+',',fil_AllowCnty+',')=0)) then
  begin
    if dmData.DebugLevel>=2 then Writeln('RBNMonitor: ','This country is not allowed - ',pfx);
    exit
  end;

  if fil_LoTWOnly and (LoTW<>'L') then
  begin
    if dmData.DebugLevel>=2 then Writeln('RBNMonitor: ','This station is not LoTW user - ',dxstn);
    exit
  end;

  if fil_eQSLOnly and (eQSL<>'E') then
  begin
    if dmData.DebugLevel>=2 then Writeln('RBNMonitor: ','This station is not eQSL user - ',dxstn);
    exit
  end;

  dmData.RbnMonDXCCInfo(adif,band,mode,DxccWithLoTW,index);
  case index of
    1 : dxinfo := 'N';
    2 : dxinfo := 'B';
    3 : dxinfo := 'M';
    else
      dxinfo := ''
  end; //case

  if fil_NewDXCOnly then
  begin
    if (index>0) and (index<4) then
    begin
      if dmData.DebugLevel>=2 then Writeln('RBNMonitor: ','Not new one, band or mode - ',dxstn);
      exit
    end
  end;

  Result := True
end;

procedure TRBNThread.Execute;
var
  spot : String;
  spotter : String;
  freq    : String;
  stren   : String;
  mode    : String;
  dxstn   : String;
  LoTW    : String;
  eQSL    : String;
  dxinfo  : String;
  RbnSpot : TRbnSpot;
  index   : Integer;
  band    : String;
begin
  reg := TRegExpr.Create;
  try try
    while not Terminated do
    begin
      EnterCriticalsection(frmRbnMonitor.csRbnMonitor);
      try
        if frmRbnMonitor.slRbnSpots.Count>0 then
        begin
          spot := frmRbnMonitor.slRbnSpots.Strings[0];
          frmRbnMonitor.slRbnSpots.Delete(0)
        end
        else
          spot := ''
      finally
        LeaveCriticalsection(frmRbnMonitor.csRbnMonitor)
      end;
      if (spot='') then
      begin
        sleep(200);
        Continue
      end;

      if (Pos('-',copy(spot,1,17))>0) then
        spotter := trim(copy(spot,7,Pos('-',spot)-7))
      else
        spotter := trim(copy(spot,7,Pos(':',spot)-7));

      freq    := trim(copy(spot,18,9));
      stren   := trim(copy(spot,Pos('dB',spot)-4,4));

      Writeln(spotter);
      Writeln(freq);

      dxstn    := copy(spot,Pos('.',spot)+3,Length(spot)-Pos('.',spot)-1);
      dxstn    := trim(dxstn);
      dxstn    := trim(copy(dxstn,1,Pos(' ',dxstn)));

      mode    := trim(copy(spot,41,6));
      Writeln(mode);
      if (Pos(','+mode+',',','+C_RBN_MODES+',') = 0) then //some rbn nodes doesn't have mode value
      begin
        mode := frmRbnMonitor.getModeFromFreq(freq)
      end;
      Writeln(mode);

      if dmDXCluster.UsesLotw(dxstn) then
        LoTW := 'L'
      else
        LoTW := '';

      if dmDXCluster.UseseQSL(dxstn) then
        eQSL := 'E'
      else
        eQSL := '';

      if AllowedSpot(spotter,dxstn,freq,mode,LoTW,eQSL,dxinfo) then
      begin
        fRbnSpot.spotter := spotter;
        fRbnSpot.dxstn   := dxstn;
        fRbnSpot.freq    := freq;
        fRbnSpot.mode    := mode;
        fRbnSpot.qsl     := LoTW+eQSL;
        fRbnSpot.dxinfo  := dxinfo;
        fRbnSpot.signal  := stren;
        Synchronize(@ShowSpot)
      end;
      Sleep(100)
    end
  except
    on E: Exception do
      Writeln('*********',E.Message)
  end
  finally
    FreeAndNil(reg)
  end
end;

///////////////////////////////////////////////////////////////////////////////////////////////////////

procedure TfrmRbnMonitor.AddSpotToThread(spot : String);
begin
  EnterCriticalsection(csRbnMonitor);
  try
     slRbnSpots.Add(spot)
  finally
    LeaveCriticalsection(csRbnMonitor)
  end
end;

procedure TfrmRbnMonitor.lConnect(aSocket: TLSocket);
begin
  tbtnConnect.Action   := acDisconnect;
  sbRbn.Panels[0].Text := 'Connected to RBN'
end;

procedure TfrmRbnMonitor.lDisconnect(aSocket: TLSocket);
begin
  tbtnConnect.Action := acConnect;
  sbRbn.Panels[0].Text := 'Disconected'
end;

procedure TfrmRbnMonitor.lReceive(aSocket: TLSocket);
const
  CR = #13;
  LF = #10;
var
  sStart, sStop: Integer;
  tmp : String;
  buffer : String;
  UserName : String;
begin
  if lTelnet.GetMessage(buffer) = 0 then
    exit;
  sStart := 1;
  sStop := Pos(CR, Buffer);
  if sStop = 0 then
    sStop := Length(Buffer) + 1;
  while sStart <= Length(Buffer) do
  begin
    tmp  := Copy(Buffer, sStart, sStop - sStart);
    tmp  := trim(tmp);
    if dmData.DebugLevel >=1 then Writeln(tmp);

    if (Pos('DX DE',UpperCase(tmp))>0)  then
    begin
      AddSpotToThread(tmp)
    end
    else begin
      UserName := cqrini.ReadString('RBNMonitor','UserName',cqrini.ReadString('Station', 'Call', ''));
      if (Pos('LOGIN',UpperCase(tmp)) > 0) and (UserName <> '') then
        lTelnet.SendMessage(UserName+#13+#10);
      if (Pos('please enter your call',LowerCase(tmp)) > 0) and (UserName <> '') then
        lTelnet.SendMessage(UserName+#13+#10)
    end;

    sStart := sStop + 1;
    if sStart > Length(Buffer) then
      Break;
    if Buffer[sStart] = LF then
      sStart := sStart + 1;
    sStop := sStart;
    while (Buffer[sStop] <> CR) and (sStop <= Length(Buffer)) do
      sStop := sStop + 1
  end;
  lTelnet.CallAction
end;

procedure TfrmRbnMonitor.acConnectExecute(Sender: TObject);
var
  port   : Integer;
  server : String;
  user   : String;
begin
  RbnMonThread := TRBNThread.Create(True);
  RbnMonThread.FreeOnTerminate := True;
  RbnMonThread.OnShowSpot := @SynRbnMonitor;
  RbnMonThread.Start;

  LoadConfigToThread;

  server := cqrini.ReadString('RBNMonitor','ServerName','telnet.reversebeacon.net:7000');
  user   := cqrini.ReadString('RBNMonitor','UserName',cqrini.ReadString('Station', 'Call', ''));

  if (user='') then
  begin
    Application.MessageBox('User name is not defined!','Warning...',mb_ok+mb_IconWarning);
    acRbnServer.Execute;
    exit
  end;

  lTelnet.Host := Copy(server,1,Pos(':',server)-1);
  if not TryStrToInt(Copy(server,Pos(':',server)+1,6),port) then
    port := 7000;
  lTelnet.Port := port;
  Writeln(server,'   ',port);
  lTelnet.Connect;
  btnEatFocus.SetFocus
end;

procedure TfrmRbnMonitor.acDisconnectExecute(Sender: TObject);
begin
  lTelnet.Disconnect();
  RbnMonThread.Terminate;
  tbtnConnect.Action := acConnect
end;

procedure TfrmRbnMonitor.acFilterExecute(Sender: TObject);
begin
  with TfrmRbnFilter.Create(frmRbnMonitor) do
  try
    if ShowModal = mrOK then
      LoadConfigToThread
  finally
    Free
  end;
  btnEatFocus.SetFocus
end;

procedure TfrmRbnMonitor.acFontSettingsExecute(Sender: TObject);
begin
  dlgFont.Font := sgRbn.Font;
  if dlgFont.Execute then
  begin
    cqrini.WriteString('RBNMonitor','Font',dlgFont.Font.Name);
    cqrini.WriteInteger('RBNMonitor','FontSize',dlgFont.Font.Size);
    sgRbn.Font := dlgFont.Font
  end;
  btnEatFocus.SetFocus
end;

procedure TfrmRbnMonitor.acHelpExecute(Sender : TObject);
begin
  ShowMessage('Not implemented, yet')
end;

procedure TfrmRbnMonitor.acRbnServerExecute(Sender: TObject);
begin
  with TfrmRbnServer.Create(frmRbnMonitor) do
  try
    edtServerName.Text := cqrini.ReadString('RBNMonitor','ServerName','telnet.reversebeacon.net:7000');
    edtUserName.Text   := cqrini.ReadString('RBNMonitor','UserName',cqrini.ReadString('Station', 'Call', ''));
    if ShowModal = mrOK then
    begin
      cqrini.WriteString('RBNMonitor','ServerName',edtServerName.Text);
      cqrini.WriteString('RBNMonitor','UserName',edtUserName.Text)
    end
  finally
    Free
  end;
  btnEatFocus.SetFocus
end;

procedure TfrmRbnMonitor.acScrollDownExecute(Sender : TObject);
begin
  sgRbn.Row := sgRbn.RowCount;
  btnEatFocus.SetFocus
end;

procedure TfrmRbnMonitor.FormClose(Sender: TObject;
  var CloseAction: TCloseAction);
var
  i : Integer;
begin
  for i:=0 to sgRbn.ColCount-1 do
    cqrini.WriteInteger('WindowSize','RbnCol'+IntToStr(i),sgRbn.ColWidths[i]);
  lTelnet.Disconnect();
  dmUtils.SaveWindowPos(self)
end;

procedure TfrmRbnMonitor.FormCreate(Sender: TObject);
begin
  InitCriticalSection(csRbnMonitor);

  DeleteCount := 0;

  sgRbn.RowCount := 1;

  slRbnSpots := TStringList.Create;

  lTelnet := TLTelnetClientComponent.Create(nil);
  lTelnet.OnConnect    := @lConnect;
  lTelnet.OnDisconnect := @lDisconnect;
  lTelnet.OnReceive    := @lReceive
end;

procedure TfrmRbnMonitor.FormDestroy(Sender: TObject);
begin
  FreeAndNil(lTelnet);
  DoneCriticalsection(csRbnMonitor);
  FreeAndNil(slRbnSpots)
end;

procedure TfrmRbnMonitor.FormShow(Sender: TObject);
var
  i : Integer;
begin
  for i:=0 to sgRbn.ColCount-1 do
    sgRbn.ColWidths[i] := cqrini.ReadInteger('WindowSize','RbnCol'+IntToStr(i),70);

  dmUtils.LoadWindowPos(self);

  sgRbn.Options   := sgRbn.Options + [goColSizing] - [goRowSelect, goRangeSelect];
  sgRbn.Font.Name := cqrini.ReadString('RBNMonitor','Font','DejaVu Sans Mono');
  sgRbn.Font.Size := cqrini.ReadInteger('RBNMonitor','FontSize',10);

  sgRbn.Cells[0,0] := 'Source';
  sgRbn.Cells[1,0] := 'Freq';
  sgRbn.Cells[2,0] := 'DX';
  sgRbn.Cells[3,0] := 'Mode';
  sgRbn.Cells[4,0] := 'dB';
  sgRbn.Cells[5,0] := 'Q';
  sgRbn.Cells[6,0] := 'D'
end;

procedure TfrmRbnMonitor.sgRbnDblClick(Sender: TObject);
begin
  frmNewQSO.NewQSOFromSpot(sgRbn.Cells[2,sgRbn.Row],sgRbn.Cells[1,sgRbn.Row],sgRbn.Cells[3,sgRbn.Row],True)
end;

procedure TfrmRbnMonitor.sgRbnDrawCell(Sender: TObject; aCol, aRow: Integer;
  aRect: TRect; aState: TGridDrawState);
begin
  {
  if (aRow>0) then
   begin
     if (Arow mod 2 > 0) then
       sgRbn.Canvas.Brush.Color:= clwhite
     else
       sgRbn.Canvas.Brush.Color:= $00E7FFEB;
     sgRbn.Canvas.FillRect(aRect);
     sgRbn.Canvas.TextOut(aRect.Left, aRect.top + 4, sgRbn.Cells[ACol, ARow])
   end }
end;

procedure TfrmRbnMonitor.sgRbnHeaderSized(Sender: TObject; IsColumn: Boolean;
  Index: Integer);
begin
  btnEatFocus.SetFocus
end;

procedure TfrmRbnMonitor.LoadConfigToThread;
begin
  if Assigned(RbnMonThread) then
  begin
    RbnMonThread.fil_SrcCont := cqrini.ReadString('RBNFilter','SrcCont',C_RBN_CONT);

    RbnMonThread.fil_IgnWkdHour    := cqrini.ReadBool('RBNFilter','IgnHour',True);
    RbnMonThread.fil_IgnHourValue  := cqrini.ReadInteger('RBNFilter','IgnHourValue',48);
    RbnMonThread.fil_IgnDate       := cqrini.ReadBool('RBNFilter','IgnDate',False);
    RbnMonThread.fil_IgnDateValue  := cqrini.ReadString('RBNFilter','IgnDateValue','');
    RbnMonThread.fil_IgnTimeValue  := cqrini.ReadString('RBNFilter','IgnTimeValue','');

    RbnMonThread.fil_AllowAllCall          := cqrini.ReadBool('RBNFilter','AllowAllCall',True);
    RbnMonThread.fil_AllowOnlyCall         := cqrini.ReadBool('RBNFilter','AllowOnlyCall',False);
    RbnMonThread.fil_AllowOnlyCallValue    := cqrini.ReadString('RBNFilter','AllowOnlyCallValue','');
    RbnMonThread.fil_AllowOnlyCallReg      := cqrini.ReadBool('RBNFilter','AllowOnlyCallReg',False);
    RbnMonThread.fil_AllowOnlyCallRegValue := cqrini.ReadString('RBNFilter','AllowOnlyCallRegValue','');

    RbnMonThread.fil_AllowCont  := cqrini.ReadString('RBNFilter','AllowCont',C_RBN_CONT);
    RbnMonThread.fil_AllowBands := cqrini.ReadString('RBNFilter','AllowBands',C_RBN_BANDS);
    RbnMonThread.fil_AllowModes := cqrini.ReadString('RBNFilter','AllowModes',C_RBN_MODES);
    RbnMonThread.fil_AllowCnty  := cqrini.ReadString('RBNFilter','AllowCnty','');
    RbnMonThread.fil_NotCnty    := cqrini.ReadString('RBNFilter','NotCnty','');

    RbnMonThread.fil_LoTWOnly := cqrini.ReadBool('RBNFilter','LoTWOnly',False);
    RbnMonThread.fil_eQSLOnly := cqrini.ReadBool('RBNFilter','eQSLOnly',False);

    RbnMonThread.fil_NewDXCOnly := cqrini.ReadBool('RBNFilter','NewDXCOnly',False)
  end
end;

procedure TfrmRbnMonitor.SynRbnMonitor(RbnSpot : TRbnSpot);
var
  i : Integer;

  procedure AddRow;
  begin
    i := sgRbn.RowCount+1;
    sgRbn.RowCount := i;
    dec(i);

    sgRbn.Cells[0,i] := RbnSpot.spotter;
    sgRbn.Cells[1,i] := RbnSpot.freq;
    sgRbn.Cells[2,i] := RbnSpot.dxstn;
    sgRbn.Cells[3,i] := RbnSpot.mode;
    sgRbn.Cells[4,i] := RbnSpot.signal;
    sgRbn.Cells[5,i] := RbnSpot.qsl;
    sgRbn.Cells[6,i] := RbnSpot.dxinfo
  end;

begin
  if sgRbn.Focused then
  begin
    inc(DeleteCount);
    AddRow
  end
  else begin
    AddRow;
    if DeleteCount>0 then
    begin
      if (sgRbn.RowCount > C_MAX_ROWS) then
      begin
        for i:=1 to DeleteCount do
          sgRbn.DeleteRow(0)
      end;
      DeleteCount := 0
    end
    else begin
      if sgRbn.RowCount>C_MAX_ROWS then
        sgRbn.DeleteRow(0)
    end;

    sgRbn.Row := sgRbn.RowCount
  end
end;

function TfrmRbnMonitor.GetModeFromFreq(freq: string): string;
var
  Band: string;
  eFreq: Currency;
begin
  Result := '';
  if TryStrToCurr(freq,eFreq) then
    eFreq := eFreq/1000
  else
    exit;

  band := dmDXCluster.GetBandFromFreq(freq, True);
  dmData.qRbnMon.Close;
  dmData.qRbnMon.SQL.Text := 'SELECT * FROM cqrlog_common.bands WHERE band = ' + QuotedStr(band);
  if dmData.DebugLevel>=1 then Writeln(dmData.qRbnMon.SQL.Text);
  if dmData.trRbnMon.Active then
    dmData.trRbnMon.Rollback;
  dmData.trRbnMon.StartTransaction;
  try
    dmData.qRbnMon.Open;
    if dmData.qRbnMon.RecordCount > 0 then
    begin
      if ((eFreq >= dmData.qRbnMon.FieldByName('B_BEGIN').AsCurrency) and
        (eFreq <= dmData.qRbnMon.FieldByName('CW').AsCurrency)) then
        Result := 'CW'
      else
      begin
        if ((eFreq > dmData.qRbnMon.FieldByName('RTTY').AsCurrency) and
          (eFreq <= dmData.qRbnMon.FieldByName('SSB').AsCurrency)) then
          Result := 'RTTY'
        else begin
          Result := 'SSB'
        end
      end
    end
  finally
    dmData.qRbnMon.Close;
    dmData.trRbnMon.Rollback
  end
end;

initialization
  {$I fRbnMonitor.lrs}

end.

