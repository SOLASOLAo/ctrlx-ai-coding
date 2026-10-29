METHOD PUBLIC Open : DINT
VAR_INPUT
  BaudRate  : OC_OpconBaseCommonDef.OpconSerialBaudRate;
  DataFrame : OC_OpconBaseCommonDef.OpconSerialDataFrame;
  Handshake : OC_OpconBaseCommonDef.OpconSerialHandshakeType;
END_VAR
(* BODY *)
ConfigurationCorrect :=
(BaudRate = OC_OpconBaseCommonDef.OpconSerialBaudRate.BAUD_9600) AND
(DataFrame = OC_OpconBaseCommonDef.OpconSerialDataFrame.FRAME_8N1) AND
(Handshake = OC_OpconBaseCommonDef.OpconSerialHandshakeType.NO_HANDSHAKE);
IF ( ConfigurationCorrect )
THEN
  IF ( InjectOpenFault )
  THEN
    Open := -21;
  ELSE
    _opened := TRUE;
    Open    := OK;
  END_IF
ELSE
  Open := -1;
END_IF
