PROGRAM PRG_AutoResult
VAR
  Client       : IN_Inntai.FB_InntaiClient;
  Serial       : FB_InntaiWireFixture;
  Parameters   : IN_Inntai.InntaiParameters;
  Stage        : UINT;
  CaseNumber   : UINT := 1;
  Execute      : BOOL;
  Reset        : BOOL;
  Cancel       : BOOL;
  DeviceReady  : BOOL := TRUE;
  Delay        : TIME;
  Age          : TON;
  Guard        : TON;
  Passed       : ARRAY[1..8] OF BOOL;
  CompletionAge : ARRAY[1..8] OF TIME;
  CompletionCycles : ARRAY[1..8] OF USINT;
  Finished     : BOOL;
  Failed       : BOOL;
  ErrorDetail  : STRING(63);
  StartBefore  : UDINT;
  CsBefore     : UDINT;
  SawPending   : BOOL;
  Premature    : BOOL;
END_VAR
(* BODY *)
IF ( Finished ) OR ( Failed )
THEN
  RETURN;
END_IF
Age(IN := Stage = 30, PT := T#10S);
Guard(IN := TRUE, PT := T#25S);
Parameters.Channel := 1;
IF ( CaseNumber = 5 )
THEN
  Parameters.Channel := 2;
END_IF
Delay := T#500MS;
IF ( CaseNumber = 2 )
THEN
  Delay := T#700MS;
END_IF
Serial.AutoResult  := ( CaseNumber <> 3 ) AND ( CaseNumber <> 8 );
Serial.StaleResult := CaseNumber = 4;
Serial.ResultDelay := T#200MS;
IF ( CaseNumber = 2 )
THEN
  Serial.ResultDelay := T#400MS;
END_IF
Serial.FreshOnRead := ( Stage = 30 ) AND ( Age.ET >= T#1S );
DeviceReady := TRUE;
IF ( Stage = 30 )
THEN
  CASE CaseNumber OF
    1:
      // Reproduce the field trace: one observed Ready cycle with pulse mode on.
      DeviceReady := Age.ET >= T#600MS;
    3:
      // Preserve the original two-cycle path when the device does not upload.
      DeviceReady := ( ( Age.ET >= T#200MS ) AND ( Age.ET < T#600MS ) ) OR
                     ( Age.ET >= T#1S );
    6:
      // A dip inside the final delay must restart the full qualification time.
      DeviceReady := ( ( Age.ET >= T#600MS ) AND ( Age.ET < T#800MS ) ) OR
                     ( Age.ET >= T#1S );
    7:
      DeviceReady := FALSE;
  END_CASE
END_IF
Serial();
Client(
  Enable             := TRUE,
  ResetError         := Reset,
  Execute            := Execute,
  Cancel             := Cancel,
  Command            := IN_Inntai.InntaiLeakTestCmd.MEASURE,
  Parameters         := Parameters,
  SerialChannel      := Serial,
  UseDeviceReady     := TRUE,
  DeviceReady        := DeviceReady,
  PulseEnabled       := TRUE,
  ResultReadDelay    := Delay,
  ResponseTimeout    := T#1S,
  MeasurementTimeout := T#1MS
);
Reset  := FALSE;
Cancel := FALSE;
IF ( Guard.Q )
THEN
  Failed      := TRUE;
  ErrorDetail := 'Fixture timeout';
END_IF
CASE Stage OF
  0:
    IF ( Client.Ready )
    THEN
      StartBefore := Serial.StartCalls;
      CsBefore    := Serial.CsCalls;
      SawPending  := FALSE;
      Premature   := FALSE;
      Execute     := TRUE;
      Stage       := 10;
    END_IF
  10:
    IF ( Client.Step = 60 )
    THEN
      Stage := 30;
    END_IF
  30:
    SawPending := SawPending OR Client.PendingResult;
    IF ( CaseNumber = 1 ) AND ( Age.ET < T#1100MS ) OR
       ( CaseNumber = 2 ) AND ( Age.ET < T#1S ) OR
       ( CaseNumber = 3 ) AND ( Age.ET < T#1500MS ) OR
       ( CaseNumber = 6 ) AND ( Age.ET < T#1500MS )
    THEN
      Premature := Premature OR Client.Done;
    END_IF
    IF ( ( CaseNumber = 4 ) OR ( CaseNumber = 8 ) ) AND
       ( Age.ET >= T#900MS )
    THEN
      Passed[CaseNumber] := Client.Busy AND NOT Client.Done AND NOT Client.PendingResult;
      Cancel := TRUE;
      Stage  := 35;
    ELSIF ( CaseNumber = 7 ) AND ( Age.ET >= T#500MS )
    THEN
      Passed[7] := SawPending AND Client.Busy AND NOT Client.Done;
      Cancel := TRUE;
      Stage  := 35;
    ELSIF ( Client.Done )
    THEN
      CompletionAge[CaseNumber]    := Age.ET;
      CompletionCycles[CaseNumber] := Client.ReadyCyclesCompleted;
      Passed[CaseNumber] := NOT Premature AND Client.ResultValid AND
                            ( Client.LastResult.RecordId = '00002' ) AND
                            ( Serial.StartCalls = StartBefore + 1 ) AND Serial.WireValid;
      IF ( CaseNumber = 3 )
      THEN
        Passed[3] := Passed[3] AND ( Client.ReadyCyclesCompleted = 2 ) AND
                     ( Serial.CsCalls = CsBefore + 2 );
      ELSE
        Passed[CaseNumber] := Passed[CaseNumber] AND SawPending AND
                              ( Serial.CsCalls = CsBefore + 1 ) AND
                              ( ( Client.ReadyCyclesCompleted < 2 ) OR
                                ( ( CaseNumber = 6 ) AND ( Client.ReadyCyclesCompleted = 2 ) ) );
      END_IF
      Execute := FALSE;
      Stage   := 40;
    ELSIF ( Client.Error ) AND ( CaseNumber = 5 )
    THEN
      Passed[5] := ( Client.ErrorId = 10 ) AND NOT Client.ResultValid AND NOT Client.Done;
      Execute := FALSE;
      Stage   := 36;
    END_IF
  35:
    IF ( Client.Error )
    THEN
      Passed[CaseNumber] := Passed[CaseNumber] AND ( Client.ErrorId = 9 ) AND
                            NOT Client.PendingResult AND NOT Client.ResultValid;
      Execute := FALSE;
      Stage   := 36;
    END_IF
  36:
    IF ( Client.Stopped )
    THEN
      Reset := TRUE;
      Stage := 40;
    END_IF
  40:
    IF ( Client.Ready )
    THEN
      IF ( NOT Passed[CaseNumber] )
      THEN
        Failed := TRUE;
      ELSIF ( CaseNumber = 8 )
      THEN
        Finished := TRUE;
      ELSE
        CaseNumber := CaseNumber + 1;
        Stage      := 0;
      END_IF
    END_IF
END_CASE
IF ( Client.Error ) AND ( Stage <> 36 ) AND ( Stage <> 40 )
THEN
  Failed      := TRUE;
  ErrorDetail := Client.ErrorDetail;
END_IF
