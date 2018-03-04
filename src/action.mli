open! Import

module Var_expansion : sig
  module Concat_or_split : sig
    type t =
      | Concat (** default *)
      | Split  (** the variable is a "split" list of items *)
  end

  type t =
    | Paths   of Path.t list * Concat_or_split.t
    | Strings of string list * Concat_or_split.t

  val to_string : Path.t -> t -> string
  (** [to_string dir v] convert the variable expansion to a string.
     If it is a path, the corresponding string will be relative to
     [dir]. *)
end

module Outputs : module type of struct include Action_intf.Outputs end

(** result of the lookup of a program, the path to it or information about the
    failure and possibly a hint how to fix it *)
module Prog : sig
  module Not_found : sig
    type t =
      { context : string
      ; program : string
      ; hint    : string option
      }

    val raise : t -> _
  end

  type t = (Path.t, Not_found.t) result
end

include Action_intf.Ast
  with type program := Prog.t
  with type path    := Path.t
  with type string  := string

include Action_intf.Helpers
  with type program := Prog.t
  with type path    := Path.t
  with type string  := string
  with type t       := t

val t : t Sexp.Of_sexp.t

module For_shell : sig
  include Action_intf.Ast
    with type program := string
    with type path    := string
    with type string  := string

  val sexp_of_t : t Sexp.To_sexp.t
end

(** Convert the action to a format suitable for printing *)
val for_shell : t -> For_shell.t

(** Return the list of directories the action chdirs to *)
val chdirs : t -> Path.Set.t

(** Ast where programs are not yet looked up in the PATH *)
module Unresolved : sig
  type action = t

  module Program : sig
    type t =
      | This   of Path.t
      | Search of string
  end

  include Action_intf.Ast
    with type program := Program.t
    with type path    := Path.t
    with type string  := string

  val resolve : t -> f:(string -> Path.t) -> action
end with type action := t

module Unexpanded : sig
  include Action_intf.Ast
    with type program := String_with_vars.t
    with type path    := String_with_vars.t
    with type string  := String_with_vars.t

  val t : t Sexp.Of_sexp.t
  val sexp_of_t : t Sexp.To_sexp.t

  module Partial : sig
    include Action_intf.Ast
      with type program = (Unresolved.Program.t, String_with_vars.t) either
      with type path    = (Path.t              , String_with_vars.t) either
      with type string  = (string              , String_with_vars.t) either

    val expand
      :  t
      -> dir:Path.t
      -> map_exe:(Path.t -> Path.t)
      -> f:(Loc.t -> String.t -> Var_expansion.t option)
      -> Unresolved.t
  end

  val partial_expand
    :  t
    -> dir:Path.t
    -> map_exe:(Path.t -> Path.t)
    -> f:(Loc.t -> string -> Var_expansion.t option)
    -> Partial.t
end

val exec : targets:Path.Set.t -> ?context:Context.t -> t -[!r async]-> unit

(* Return a sandboxed version of an action *)
val sandbox
  :  t
  -> sandboxed:(Path.t -> Path.t)
  -> deps:Path.t list
  -> targets:Path.t list
  -> t

(** Infer dependencies and targets.

    This currently doesn't support well (rename ...) and (remove-tree ...). However these
    are not exposed in the DSL.
*)
module Infer : sig
  module Outcome : sig
    type t =
      { deps    : Path.Set.t
      ; targets : Path.Set.t
      }
  end

  val infer : t -> Outcome.t

  (** If [all_targets] is [true] and a target cannot be determined statically, fail *)
  val partial : all_targets:bool -> Unexpanded.Partial.t -> Outcome.t

  (** Return the list of targets of an unexpanded action. *)
  val unexpanded_targets : Unexpanded.t -> String_with_vars.t list
end

module Promotion : sig
  module File : sig
    type t =
      { src : Path.t
      ; dst : Path.t
      }

    (** Register a file to promote *)
    val register : t -> unit
  end

  (** Promote all registered files if [!Clflags.auto_promote]. Otherwise dump the list of
      registered files to [_build/.to-promote]. *)
  val finalize : unit -> unit

  val promote_files_registered_in_last_run : unit -> unit
end
