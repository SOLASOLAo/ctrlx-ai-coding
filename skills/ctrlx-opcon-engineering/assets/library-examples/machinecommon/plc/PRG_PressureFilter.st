(* ===== DECLARATION ===== *)
PROGRAM PRG_PressureFilter
VAR
  P : ARRAY[1..14] OF MachineCommon.FB_MainPressureControl;
  Pass : ARRAY[1..16] OF BOOL;
  First : BOOL := TRUE;
  Phase : UINT;
  Mark : TIME;
  Elapsed : TIME;
  LossElapsed : TIME;
  CustomLossElapsed : TIME;
  I : INT;
  High : BOOL;
  Low : BOOL;
  Monitoring : BOOL;
  ControlOn : BOOL;
  Release : BOOL;
  Timeout : TIME;
  Filter : TIME;
  Finished : BOOL;
  Failed : BOOL;
END_VAR
(* ===== IMPLEMENTATION ===== *)
IF ( Finished ) THEN RETURN; END_IF
IF ( First )
THEN
  FOR I := 1 TO 16 DO Pass[I] := TRUE; END_FOR
  First := FALSE;
  Mark := TIME();
END_IF
Elapsed := TIME() - Mark;
FOR I := 1 TO 14 DO
  Monitoring := TRUE;
  ControlOn := TRUE;
  Release := TRUE;
  High := Phase <> 0;
  Low := NOT High;
  Timeout := T#5S;
  Filter := T#200MS;
  IF ( I = 4 ) THEN Filter := T#0MS; END_IF
  IF ( I = 11 ) THEN Filter := T#350MS; END_IF
  IF ( I = 5 ) THEN Timeout := T#150MS; High := FALSE; Low := TRUE; END_IF
  IF ( I = 10 ) THEN Timeout := T#150MS; ControlOn := FALSE; High := TRUE; Low := FALSE; END_IF
  IF ( I = 13 ) THEN High := FALSE; Low := TRUE; END_IF
  IF ( Phase = 2 )
  THEN
    CASE I OF
      1: High := Elapsed >= T#300MS; Low := NOT High;
      2: High := Elapsed >= T#100MS; Low := NOT High;
      3: High := (TIME_TO_UDINT(Elapsed) / 60) MOD 2 = 1; Low := NOT High;
      4, 11: High := FALSE; Low := TRUE;
      6: High := TRUE; Low := TRUE;
      7: ControlOn := FALSE;
      8: Release := FALSE;
      9: Monitoring := FALSE;
      12: High := FALSE; Low := FALSE;
      14: ControlOn := Elapsed >= T#50MS; High := Elapsed >= T#300MS; Low := NOT High;
    END_CASE
  END_IF
  IF ( Phase = 3 ) AND ( I = 1 )
  THEN
    ControlOn := FALSE; High := FALSE; Low := TRUE;
  END_IF
  P[I](xMonitoringEnabled := Monitoring, xControlOnOk := ControlOn,
       xValveRelease := Release, xPressureHigh := High, xPressureLow := Low,
       tMonitoringTime := Timeout, tPressureLossFilterTime := Filter);
END_FOR

CASE Phase OF
  0:
    // No pressure feedback means no initial Ready, even with the valve opened.
    Pass[15] := NOT P[1].xPressureReady AND P[1].xValveOn AND
                (P[1].tMonitoringTime = T#5S) AND
                (P[1].tPressureLossFilterTime = T#200MS);
    Phase := 1; Mark := TIME();
  1:
    IF ( Elapsed >= T#30MS )
    THEN
      FOR I := 1 TO 14 DO
        IF ( I <> 5 ) AND ( I <> 10 ) AND ( I <> 13 )
        THEN Pass[I] := P[I].xPressureReady AND P[I].xValveOn AND P[I].xEnableControlOn;
        END_IF
      END_FOR
      Phase := 2; Mark := TIME();
    END_IF
  2:
    IF ( Elapsed < T#200MS )
    THEN
      Pass[1] := Pass[1] AND P[1].xPressureReady AND P[1].xValveOn AND P[1].xEnableControlOn;
      Pass[12] := Pass[12] AND P[12].xPressureReady AND NOT P[12].xFaultPressureNotHigher;
    END_IF
    IF ( P[1].xFaultPressureNotHigher ) AND ( LossElapsed = T#0MS ) THEN LossElapsed := Elapsed; END_IF
    IF ( Elapsed >= T#250MS )
    THEN
      Pass[1] := Pass[1] AND P[1].xFaultPressureNotHigher AND NOT P[1].xValveOn AND
                 NOT P[1].xPressureReady AND NOT P[1].xEnableControlOn;
      Pass[12] := Pass[12] AND P[12].xFaultPressureNotHigher AND NOT P[12].xPressureReady;
    END_IF
    Pass[2] := Pass[2] AND P[2].xPressureReady AND P[2].xValveOn AND P[2].xEnableControlOn AND NOT P[2].xFaultPressureNotHigher;
    Pass[3] := Pass[3] AND P[3].xPressureReady AND NOT P[3].xFaultPressureNotHigher;
    IF ( Elapsed >= T#10MS ) THEN
      Pass[4] := Pass[4] AND P[4].xFaultPressureNotHigher AND NOT P[4].xValveOn AND NOT P[4].xEnableControlOn;
    END_IF
    Pass[6] := Pass[6] AND P[6].xPressureSignalConflict AND P[6].xFaultPressureNotHigher AND P[6].xFaultPressureNotLower AND NOT P[6].xValveOn;
    Pass[7] := Pass[7] AND NOT P[7].xValveOn AND NOT P[7].xPressureReady;
    Pass[8] := Pass[8] AND NOT P[8].xValveOn AND NOT P[8].xPressureReady;
    Pass[9] := Pass[9] AND NOT P[9].xValveOn AND NOT P[9].xPressureReady AND NOT P[9].xEnableControlOn;
    Pass[13] := Pass[13] AND NOT P[13].xPressureReady AND NOT P[13].xFaultPressureNotHigher;
    IF ( Elapsed < T#350MS ) THEN
      Pass[11] := Pass[11] AND P[11].xPressureReady AND NOT P[11].xFaultPressureNotHigher;
    END_IF
    IF ( P[11].xFaultPressureNotHigher ) AND ( CustomLossElapsed = T#0MS ) THEN CustomLossElapsed := Elapsed; END_IF
    IF ( Elapsed >= T#400MS ) THEN
      Pass[11] := Pass[11] AND P[11].xFaultPressureNotHigher AND NOT P[11].xValveOn;
    END_IF
    IF ( Elapsed < T#300MS ) THEN
      Pass[14] := Pass[14] AND NOT P[14].xPressureReady AND NOT P[14].xFaultPressureNotHigher;
    ELSIF ( Elapsed >= T#350MS ) THEN
      Pass[14] := Pass[14] AND P[14].xPressureReady AND P[14].xValveOn;
    END_IF
    IF ( Elapsed >= T#500MS )
    THEN
      Pass[1] := Pass[1] AND (LossElapsed >= T#200MS) AND (LossElapsed <= T#250MS);
      Pass[11] := Pass[11] AND (CustomLossElapsed >= T#350MS) AND (CustomLossElapsed <= T#400MS);
      Pass[5] := P[5].xFaultPressureNotHigher AND NOT P[5].xValveOn AND NOT P[5].xPressureReady;
      Pass[10] := P[10].xFaultPressureNotLower AND NOT P[10].xValveOn;
      Phase := 3;
    END_IF
  3:
    Pass[16] := NOT P[1].xFaultPressureNotHigher AND NOT P[1].xFaultPressureNotLower AND NOT P[1].xValveOn AND NOT P[1].xPressureReady;
    FOR I := 1 TO 16 DO Failed := Failed OR NOT Pass[I]; END_FOR
    Finished := TRUE;
END_CASE
