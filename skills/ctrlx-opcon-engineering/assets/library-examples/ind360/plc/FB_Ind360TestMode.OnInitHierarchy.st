METHOD PUBLIC OnInitHierarchy
(* BODY *)
SUPER^.OnInitHierarchy();
Scale.InstanceID := 2;
Scale.AddExtension(Extension);
AddUnit(Scale);
