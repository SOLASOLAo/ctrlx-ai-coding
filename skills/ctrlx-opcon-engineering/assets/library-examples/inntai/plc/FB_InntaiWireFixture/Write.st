METHOD PUBLIC Write : DINT
VAR_INPUT
  pData         : POINTER TO BYTE;
  DataLen       : SIZE_T;
  rBytesWritten : REFERENCE TO SIZE_T;
END_VAR
VAR
  _bcc : BYTE;
  _i   : UINT;
END_VAR
(* BODY *)
_bcc := 0;
FOR _i := 0 TO TO_UINT(DataLen) - 2
DO
  _bcc := _bcc XOR pData[_i];
END_FOR
WireValid := WireValid AND ( pData[0] = 2 ) AND
             ( pData[DataLen-2] = 3 ) AND ( _bcc = pData[DataLen-1] );
IF ( NOT WireValid )
THEN
  Write := -10009;
  RETURN;
END_IF
IF ( pData[1] = 82 ) AND
   ( pData[2] = 80 )
THEN
  FOR _i := 0 TO SIZEOF(ReplyParameters) - 1
  DO
    _queue[_i] := ReplyParameters[_i];
  END_FOR
  _count := SIZEOF(ReplyParameters);
ELSIF ( pData[1] = 67 ) AND
      ( pData[2] = 83 )
THEN
  CsCalls := CsCalls + 1;
  FOR _i := 0 TO SIZEOF(ReplyBaseline) - 1
  DO
    IF ( FreshOnRead ) THEN
      _queue[_i] := ReplyFresh[_i];
    ELSE
      _queue[_i] := ReplyBaseline[_i];
    END_IF
  END_FOR
  _count := SIZEOF(ReplyBaseline);
ELSE
  FOR _i := 0 TO SIZEOF(ReplyOk) - 1
  DO
    _queue[_i] := ReplyOk[_i];
  END_FOR
  _count   := SIZEOF(ReplyOk);
  _pending := AutoResult AND ( pData[1] = 83 ) AND ( pData[2] = 84 );
  IF ( pData[1] = 83 ) AND ( pData[2] = 84 ) THEN
    StartCalls := StartCalls + 1;
  END_IF
END_IF
IF ( SuppressReply )
THEN
  _count := 0;
END_IF
rBytesWritten := DataLen;
Write         := OK;
