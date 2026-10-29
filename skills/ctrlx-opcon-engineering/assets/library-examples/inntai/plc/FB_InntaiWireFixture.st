FUNCTION_BLOCK FB_InntaiWireFixture EXTENDS OC_AtmoEcBcEx600x.EcBcEx600xChan
VAR_INPUT
  Port            : UINT;
  AutoResult : BOOL;
  FreshOnRead : BOOL;
  StartCalls : UDINT;
  CsCalls : UDINT;
  InjectOpenFault : BOOL;
  SuppressReply   : BOOL;
  StaleResult     : BOOL;
  ResultDelay     : TIME := T#400MS;
END_VAR
VAR_OUTPUT
  ConfigurationCorrect : BOOL;
  AlreadyClosedCalls   : UDINT;
  ReadChunks           : UDINT;
  MaxReadChunk         : UINT;
  WireValid            : BOOL := TRUE;
END_VAR
VAR
  _opened         : BOOL;
  _queue          : ARRAY[0..511] OF BYTE;
  _count          : UINT;
  _pending        : BOOL;
  _i              : UINT;
  _resultTimer    : TON;
  ReplyOk         : ARRAY[0..4] OF BYTE := [2,79,75,3,5];
  ReplyParameters : ARRAY[0..109] OF BYTE := [2,48,49,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,46,48,48,48,48,48,48,48,48,48,48,48,48,53,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,50,48,46,48,48,48,45,48,50,48,46,48,48,48,48,48,48,48,48,48,48,46,48,48,48,48,48,48,46,48,48,48,49,50,48,46,48,48,48,49,53,48,46,48,48,48,49,48,48,46,48,3,46];
  ReplyBaseline   : ARRAY[0..77] OF BYTE := [2,67,83,48,48,48,48,49,50,48,50,54,48,57,50,56,49,50,48,48,48,48,48,48,49,83,73,77,45,80,65,82,84,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,48,48,49,50,46,51,52,48,49,48,49,48,48,48,49,50,48,46,53,48,48,3,72];
  ReplyFresh      : ARRAY[0..77] OF BYTE := [2,67,83,48,48,48,48,50,50,48,50,54,48,57,50,56,49,50,48,48,48,48,48,48,49,83,73,77,45,80,65,82,84,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,48,48,49,50,46,51,52,48,49,48,49,48,48,48,49,50,48,46,53,48,48,3,75];
END_VAR
(* BODY *)
_resultTimer(IN := _pending, PT := ResultDelay);
IF ( _pending ) AND
   ( _resultTimer.Q ) AND
   ( _count = 0 )
THEN
  FOR _i := 0 TO SIZEOF(ReplyFresh) - 1
  DO
    IF ( StaleResult )
    THEN
      _queue[_i] := ReplyBaseline[_i];
    ELSE
      _queue[_i] := ReplyFresh[_i];
    END_IF
  END_FOR
  _count   := SIZEOF(ReplyFresh);
  _pending := FALSE;
END_IF
