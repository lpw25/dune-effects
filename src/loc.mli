type t = Usexp.Loc.t =
  { start : Lexing.position
  ; stop  : Lexing.position
  }

val of_lexbuf : Lexing.lexbuf -> t

exception Error of t * string

val exnf : t -> ('a, Format.formatter, unit, exn, ![io | !~]) format4e ~> 'a
val fail : t -> ('a, Format.formatter, unit, 'b , ![io | !~]) format4e ~> 'a
val fail_lex :
  Lexing.lexbuf -> ('a, Format.formatter, unit, 'b , ![io | !~]) format4e ~> 'a
val fail_opt :
  t option -> ('a, Format.formatter, unit, 'b , ![io | !~]) format4e ~> 'a

val in_file : string -> t

(** To be used with [__POS__] *)
val of_pos : (string * int * int * int) -> t

val none : t

val to_file_colon_line : t -> string
val pp_file_colon_line : Format.formatter -> t -> unit

(** Prints "File ..., line ..., characters ...:\n" *)
val print : Format.formatter -> t -> unit

(** Prints a warning *)
val warn : t -> ('a, Format.formatter, unit, ![io | !~]) formate ~> 'a
