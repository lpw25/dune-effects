open! Import

module Syntax : sig
  type t = OCaml | Reason
end

module File : sig
  type t =
    { name : string
    ; syntax: Syntax.t
    }

  val to_ocaml : t -> t
end

type t =
  { name      : string (** Name of the module. This is always the basename of the filename
                           without the extension. *)
  ; impl      : File.t option
  ; intf      : File.t option

  ; obj_name  : string (** Object name. It is different from [name] for wrapped
                           modules. *)
  }

val name : t -> string

(** Real unit name once wrapped. This is always a valid module name. *)
val real_unit_name : t -> string

val file      : t -> dir:    Path.t -> Ml_kind.t -> Path.t option
val cm_source : t -> dir:    Path.t -> Cm_kind.t -> Path.t option
val cm_file   : t -> obj_dir:Path.t -> Cm_kind.t -> Path.t option
val cmt_file  : t -> obj_dir:Path.t -> Ml_kind.t -> Path.t option

val obj_file : t -> obj_dir:Path.t -> ext:string -> Path.t

(** Same as [cm_file] but doesn't raise if [cm_kind] is [Cmo] or [Cmx]
    and the module has no implementation. *)
val cm_file_unsafe : t -> obj_dir:Path.t -> Cm_kind.t -> Path.t

val odoc_file : t -> doc_dir:Path.t -> Path.t

(** Either the .cmti, or .cmt if the module has no interface *)
val cmti_file : t -> obj_dir:Path.t -> Path.t

val iter : t -> f:(Ml_kind.t -> File.t -> unit) -> unit

val has_impl : t -> bool

(** Set the [obj_name] field of the module. [wrapper] might be a library name. *)
val set_obj_name : t -> wrapper:string option -> t
