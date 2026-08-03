type status = Ready | Failed of string

type record = {
  first : int;
  second : string;
}

type poly = [ `One | `Two ]
