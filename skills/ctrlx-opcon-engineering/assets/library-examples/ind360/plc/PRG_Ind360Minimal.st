PROGRAM PRG_Ind360Minimal
VAR
  Root       : OC_OpconBase.OpconRootNode;
  Mode       : FB_Ind360TestMode;
  Tcp        : OC_AtmoIpDataStream.AtmoIpDataStream;
  Unit       : REFERENCE TO IN_Ind360.Ind360ScaleUnit;
  Extension  : REFERENCE TO IN_Ind360.Ind360ScaleExtension;
  Clock      : OC_OpconBase.OpconSystemTimeRtc;
  First      : BOOL := TRUE;
  Configured : BOOL;
  Ready      : BOOL;
  Finished   : BOOL;
END_VAR
(* BODY *)
Unit REF= Mode.Scale;
Extension REF= Mode.Extension;
Root.OnCycleStart();
IF ( First )
THEN
  // Local example only. Replace this endpoint for a different station.
  Tcp.ParCfg.Hostname           := '127.0.0.1';
  Tcp.ParCfg.PortNo             := 1026;
  Tcp.ParCfg.CloseSocketOnReset := TRUE;
  Tcp.UpdateInputs(Configuration := TRUE, OnlineChange := FALSE);
  Mode.InstanceID                   := 1;
  Unit.ParCfg.iChannel               := Tcp;
  Extension.ParImm.Enable            := TRUE;
  Extension.ParImm.ResponseTimeout   := T#5S;
  Extension.ParImm.MaxWeightAge       := T#5S;
  Root.TimeProvider := Clock;
  Root.AddUnit(Mode);
  First := FALSE;
END_IF
Mode.UnitStateReq := OC_OpconBase.OpconUnitStateReq.OPERATIONAL;
Mode.CommonManRelease := TRUE;
Mode.ExtensionTokenReq := 1;
Extension.UnitStateRequest := OC_OpconBase.OpconUnitStateReq.OPERATIONAL;
Extension.Heartbeat := NOT Extension.Heartbeat;
Root();
Root.OnCycleEnd();
Configured := Unit.OutImm.Configured;
Ready := Extension.OutImm.Ready AND Extension.ReleaseReadInstant;
Finished := Configured AND Ready;
// This example verifies configuration and OpCon Ready only; it sends no command.
