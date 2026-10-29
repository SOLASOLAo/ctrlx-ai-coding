METHOD PUBLIC Close : DINT
(* BODY *)
IF ( NOT _opened )
THEN
  AlreadyClosedCalls := AlreadyClosedCalls + 1;
  Close              := -601;
ELSE
  _opened := FALSE;
  Close   := OK;
END_IF
