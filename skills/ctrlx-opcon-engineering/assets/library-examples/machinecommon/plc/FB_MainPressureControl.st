(*
  Canonical AI-owned POU source.
  Deploy only through PLC Engineering MCP and verify by readback + compile.
*)

(* ===== DECLARATION ===== *)
(* Version: V1.0.0 *)
FUNCTION_BLOCK FB_MainPressureControl
VAR_INPUT
  /// Enable monitoring only after Station is OPERATIONAL and the I/O bus is OK
  xMonitoringEnabled : BOOL;
  /// Electrical safety circuit feedback from ControlOn.OutImm.IsCtrlOn
  xControlOnOk       : BOOL;
  /// Additional application interlock for opening the master air valve
  xValveRelease      : BOOL;
  /// Pressure below the lower threshold (primary MAX < 0.3 bar)
  xPressureLow       : BOOL;
  /// Pressure above the upper threshold (primary MAX > 4.5 bar)
  xPressureHigh      : BOOL;
  /// Maximum time allowed for each pressure transition
  tMonitoringTime   : TIME := T#5S;
  /// Continuous loss of established pressure before tripping; zero disables filtering
  tPressureLossFilterTime : TIME := T#200MS;
END_VAR
VAR_OUTPUT
  /// Command for the configured master air valve
  xValveOn                : BOOL;
  /// Established operating pressure; retained during brief feedback dropouts
  xPressureReady          : BOOL;
  /// Connect to ControlOn.ParImm.UserEnableControlOn
  xEnableControlOn        : BOOL;
  /// Latched fault: pressure did not reach the upper threshold
  xFaultPressureNotHigher : BOOL;
  /// Latched fault: pressure did not reach the lower threshold
  xFaultPressureNotLower  : BOOL;
  /// Current plausibility error: both pressure switches are active
  xPressureSignalConflict : BOOL;
END_VAR
VAR
  _timerPressureHigh : TON;
  _timerPressureLow  : TON;
  _pressureEstablished : BOOL;
END_VAR

(* ===== IMPLEMENTATION ===== *)
// Outside the valid application/I/O state, actively close the valve and do not
// evaluate uninitialized bus inputs.
IF ( NOT xMonitoringEnabled )
THEN
  _timerPressureHigh(IN := FALSE, PT := tMonitoringTime);
  _timerPressureLow(IN := FALSE, PT := tMonitoringTime);
  _pressureEstablished := FALSE;

  xValveOn                := FALSE;
  xPressureReady          := FALSE;
  xEnableControlOn        := FALSE;
  xFaultPressureNotHigher := FALSE;
  xFaultPressureNotLower  := FALSE;
  xPressureSignalConflict := FALSE;
  RETURN;
END_IF

// The two pressure switches describe mutually exclusive pressure ranges.
xPressureSignalConflict := ( xPressureLow ) AND
                           ( xPressureHigh );

// Accept pressure as soon as the high feedback is plausible. Once established,
// use the dropout filter instead of the initial pressure build-up timeout.
IF ( xValveOn ) AND ( xPressureHigh ) AND ( NOT xPressureLow )
THEN
  _pressureEstablished := TRUE;
END_IF

_timerPressureHigh(
  IN := ( xValveOn ) AND
        ( NOT ( ( xPressureHigh ) AND ( NOT xPressureLow ) ) ),
  PT := SEL(_pressureEstablished, tMonitoringTime, tPressureLossFilterTime)
);

_timerPressureLow(
  IN := ( NOT xValveOn ) AND
        ( NOT ( ( xPressureLow ) AND ( NOT xPressureHigh ) ) ),
  PT := tMonitoringTime
);

// A contradictory feedback is diagnosed immediately. Transition faults use
// the configured delay. Recovery resets the dropout timer, so separate short
// dropouts cannot accumulate. Faults remain latched until Control On is removed and
// a plausible depressurized state has been reached.
IF ( xPressureSignalConflict )
THEN
  xFaultPressureNotHigher := TRUE;
  xFaultPressureNotLower  := TRUE;
ELSE
  IF ( _timerPressureHigh.Q )
  THEN
    xFaultPressureNotHigher := TRUE;
  END_IF

  IF ( _timerPressureLow.Q )
  THEN
    xFaultPressureNotLower := TRUE;
  END_IF
END_IF

IF ( NOT xControlOnOk ) AND
   ( xPressureLow ) AND
   ( NOT xPressureHigh )
THEN
  xFaultPressureNotHigher := FALSE;
  xFaultPressureNotLower  := FALSE;
END_IF

// Fail-safe output behavior:
// - no electrical Control On feedback => close the valve
// - missing application release => close the valve
// - any pressure fault => close the valve
// - opening is permitted only from a plausible depressurized state
IF ( NOT xControlOnOk ) OR
   ( NOT xValveRelease ) OR
   ( xFaultPressureNotHigher ) OR
   ( xFaultPressureNotLower )
THEN
  xValveOn := FALSE;
ELSIF ( NOT xValveOn ) AND
      ( xPressureLow ) AND
      ( NOT xPressureHigh )
THEN
  xValveOn := TRUE;
END_IF

// Electrical/interlock loss and disabling the valve are never delayed.
IF ( NOT xValveOn )
THEN
  _pressureEstablished := FALSE;
END_IF

xPressureReady := ( xValveOn ) AND
                  ( xValveRelease ) AND
                  ( _pressureEstablished ) AND
                  ( NOT xFaultPressureNotHigher ) AND
                  ( NOT xFaultPressureNotLower );

xEnableControlOn := ( NOT xFaultPressureNotHigher ) AND
                    ( NOT xFaultPressureNotLower );
