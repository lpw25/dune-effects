(** Scheduling *)
open Import

(** [go ?log ?config ?gen_status_line fiber] runs the following fiber until it
    terminates. [gen_status_line] is used to print a status line when [config.display =
    Progress]. *)
val go
  :  ?log:Log.t
  -> ?config:Config.t
  -> ?gen_status_line:(unit -> string option)
  -> (unit ~[!~ async]~> 'a)
  ~> 'a

(** Wait for the following process to terminate *)
val wait_for_process : int -[!r async]-> Unix.process_status

(** Set the status line generator for the current scheduler *)
val set_status_line_generator : (unit -> string option) -[!r async]-> unit

(** Scheduler informations *)
type t

(** Wait until less tham [!Clflags.concurrency] external processes are running and return
    the scheduler informations. *)
val wait_for_available_job : unit -[!r async]-> t

(** Logger *)
val log : t -> Log.t

(** Execute the given callback with current directory temporarily changed *)
val with_chdir : t -> dir:string -> f:(unit -> 'a) -> 'a

(** Display mode for this scheduler *)
val display : t -> Config.Display.t

(** Print something to the terminal *)
val print : t -> string -> unit
