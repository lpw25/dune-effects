open Import
open Jbuild

module Jbuilds : sig
  type t

  val eval
    :  t
    -> context:Context.t
    -[async]-> (Path.t * Scope_info.t * Stanzas.t) list
end

type conf =
  { file_tree : File_tree.t
  ; jbuilds   : Jbuilds.t
  ; packages  : Package.t String_map.t
  ; scopes    : Scope_info.t list
  }

val load
  :  ?extra_ignored_subtrees:Path.Set.t
  -> ?ignore_promoted_rules:bool
  -> unit
  -> conf
