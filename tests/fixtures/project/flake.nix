{
  description = "ArchLens fixture";

  outputs = { self }:
    let
      service = {
        port = 8080;
      };
      selected = service;
    in
    {
      inherit service selected;
    };
}
