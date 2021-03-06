(** String with variables of the form ${...} or $(...)

    Variables cannot contain "${", "$(", ")" or "}". For instance in "$(cat ${x})", only
    "${x}" will be considered a variable, the rest is text. *)

open Import

type t
(** A sequence of text and variables. *)

val t : t Sexp.Of_sexp.t
(** [t ast] takes an [ast] sexp and returns a string-with-vars.  This
   function distinguishes between unquoted variables — such as ${@} —
   and quoted variables — such as "${@}". *)

val loc : t -> Loc.t
(** [loc t] returns the location of [t] — typically, in the jbuild file. *)

val sexp_of_t : t -> Sexp.t

val to_string : t -> string

(** [t] generated by the OCaml code. The first argument should be
   [__POS__]. The second is either a string to parse, a variable name
   or plain text.  [quoted] says whether the string is quoted ([false]
   by default). *)
val virt       : ?quoted: bool -> (string * int * int * int) -> string -> t
val virt_var   : ?quoted: bool -> (string * int * int * int) -> string -> t
val virt_text  : (string * int * int * int) -> string -> t

val vars : t -> String_set.t
(** [vars t] returns the set of all variables in [t]. *)

val fold : t -> init:'a -> f:('a -> Loc.t -> string -> 'a) -> 'a
(** [fold t ~init ~f] fold [f] on all variables of [t], the text
   portions being ignored. *)

val iter : t -> f:(Loc.t -> string -> unit) -> unit
(** [iter t ~f] iterates [f] over all variables of [t], the text
   portions being ignored. *)

module type EXPANSION = sig
  type t
  (** The value to which variables are expanded. *)

  val is_multivalued : t -> bool
  (** Report whether the value is a multivalued one (such as for
     example ${@}) which much be in quoted strings to be concatenated
     to text or other variables. *)

  type context
  (** Context needed to expand values of type [t] to strings. *)

  val to_string : context -> t -> string
  (** When needing to expand with text portions or if the
     string-with-vars is quoted, the value is converted to a string
     using [to_string]. *)
end

module Expand_to(V : EXPANSION) : sig
  val expand : V.context -> t -> f:(Loc.t -> string -> V.t option) ->
               (V.t, string) Either.t
  (** [expand t ~f] return [t] where all variables have been expanded
     using [f].  If [f loc var] return [Some x], the variable [var] is
     replaced by [x]; otherwise, the variable is inserted as [${var}]
     or [$(var)] — depending on the original concrete syntax used.  *)

  val partial_expand :
    V.context -> t -> f:(Loc.t -> string -> V.t option) ->
    ((V.t, string) either, t) Either.t
  (** [partial_expand t ~f] is like [expand_generic] where all
     variables that could be expanded (i.e., those for which [f]
     returns [Some _]) are.  If all the variables of [t] were
     expanded, a string is returned.  If [f] returns [None] on at
     least a variable of [t], it returns a string-with-vars. *)
end

val expand :
  t -> f:(Loc.t -> string -> string option) -> string
(** Specialized version [Expand_to.expand] that returns a string (so
   variables are assumed to expand to a single value). *)

val partial_expand :
  t -> f:(Loc.t -> string -> string option) -> (string, t) Either.t
(** [partial_expand] is a specialized version of
   [Expand_to.partial_expand] that returns a string. *)
