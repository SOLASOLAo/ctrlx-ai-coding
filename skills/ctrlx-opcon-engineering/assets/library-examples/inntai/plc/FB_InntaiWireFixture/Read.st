METHOD PUBLIC Read : DINT
VAR_INPUT
  pData        : POINTER TO BYTE;
  DataLen      : SIZE_T;
  rBytesRead   : REFERENCE TO SIZE_T;
  rReadTimeout : REFERENCE TO BOOL;
END_VAR
VAR
  _chunk : UINT;
  _i     : UINT;
END_VAR
(* BODY *)
_chunk := MIN(TO_UINT(DataLen), MIN(_count, 17));
IF ( _chunk > 0 )
THEN
  FOR _i := 0 TO _chunk - 1
  DO
    pData[_i] := _queue[_i];
  END_FOR
  _count := _count - _chunk;
  IF ( _count > 0 )
  THEN
    FOR _i := 0 TO _count - 1
    DO
      _queue[_i] := _queue[_i + _chunk];
    END_FOR
  END_IF
  ReadChunks   := ReadChunks + 1;
  MaxReadChunk := MAX(MaxReadChunk, _chunk);
END_IF
rBytesRead   := _chunk;
rReadTimeout := ( _chunk = 0 );
Read         := OK;
