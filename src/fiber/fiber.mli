(** Concurrency library *)

(** {1 Generals} *)

(** Type of asynchronous operations  *)
type ('a, !r) op

effect !r async = ![ Async : 'a. ('a, !r) op -> 'a ]

(** {1 Forking execution} *)

module Future : sig
  (** A future represent a promise that will eventually yield a value. It is used to
      represent the result of a fiber running in the background. *)
  type 'a t

  (** Wait for the given future to yield a value. *)
  val wait : 'a t -[!r async]-> 'a

end

(** [fork f] creates a sub-fiber and return a [Future.t] to wait its result. *)
val fork : (unit -[!r async | !r]-> 'a) -[!r async]-> 'a Future.t

(** [nfork l] is similar to [fork] but creates [n] sub-fibers. *)
val nfork : (unit -[!r async | !r]-> 'a) list -[!r async]-> 'a Future.t list

(** [nfork_map l ~f] is the same as [nfork (List.map l ~f:(fun x () -> f x))] but more
    efficient. *)
val nfork_map : 'a list ->> f:('a -[!r async | !r]-> 'b) -[!r async]-> 'b Future.t list

(** {1 Forking + joining} *)

(** The following functions combine forking 2 or more fibers followed by joining the
    results. For every function, we give an equivalent implementation using the more basic
    functions as documentation. Note however that these functions are implemented as
    primitives and so are more efficient that the suggested implementation. *)

(** For two fibers and wait for their results:

    {[
      let fork_and_join f g =
        fork f >>= fun a ->
        fork g >>= fun b ->
        both (Future.wait a) (Future.wait b)
      ]}
*)
val fork_and_join : (unit -[!r async | !r]-> 'a) ->> (unit -[!r async | !r]-> 'b) -[!r async]-> 'a * 'b

(** Same but assume the first fiber returns [unit]:

    {[
      let fork_and_join_unit f g =
        fork f >>= fun a ->
        fork g >>= fun b ->
        Future.wait a >>> Future.wait b
    ]}
*)
val fork_and_join_unit : (unit -[!r async | !r]-> unit) ->> (unit -[!r async | !r]-> 'a) -[!r async]-> 'a

(** Map a list in parallel:

    {[
      let parallel_map l ~f =
        nfork_map l ~f >>= fun futures ->
        all (List.map futures ~f:Future.wait)
    ]}
*)
val parallel_map : 'a list ->> f:('a -[!r async | !r]-> 'b) -[!r async]-> 'b list

(** Iter over a list in parallel:

    {[
      let parallel_iter l ~f =
        nfork_map l ~f >>= fun futures ->
        all_unit (List.map futures ~f:Future.wait)
    ]}
*)
val parallel_iter : 'a list ->> f:('a -[!r async | !r]-> unit) -[!r async]-> unit

(** {1 Local storage} *)

(** Variables local to a fiber *)
module Var : sig
  type 'a t

  (** Create a new variable *)
  val create : unit -> 'a t

  (** [get var] is a fiber that reads the value of [var] *)
  val get : 'a t -[!r async]-> 'a option

  (** Same as [get] but raises if [var] is unset. *)
  val get_exn : 'a t -[!r async]-> 'a

  (** [set var value fiber] sets [var] to [value] during the execution
      of [fiber].

      For instance, the following fiber always evaluate to [true]:

      {[
        set v x (get_exn v >>| fun y -> x = y)
      ]}
 *)
  val set : 'a t ->> 'a ->> (unit -[!r async | !r]-> 'c) -[!r async]-> 'c
end

(** {1 Error handling} *)

(** [with_error_handler f ~on_error] calls [on_error] for every exception raised during
    the execution of [f]. This include exceptions raised when calling [f ()] or during the
    execution of fibers after [f ()] has returned. Exceptions raised by [on_error] are
    passed on to the parent error handler.

    It is guaranteed that after the fiber has returned a value, [on_error] will never be
    called.
*)
val with_error_handler
  :  (unit -[!r async | !r]-> 'a)
  -> on_error:(exn -> unit)
  -[!r async]-> 'a

(** If [t] completes without raising, then [wait_errors t] is the same as [t () >>| fun x
    -> Ok x]. However, if the execution of [t] is aborted by an exception, then
    [wait_errors t] will complete and yield [Error ()].

    Note that [wait_errors] only completes after all sub-fibers have completed. For
    instance, in the following code [wait_errors] will only complete after 3s:

    {[
      wait_errors
        (fork_and_join
           (fun () -> sleep 1 >>| fun () -> raise Exit)
           (fun () -> sleep 3))
    ]}

    same for this code:

    {[
      wait_errors
        (fork (fun () -> sleep 3) >>= fun _ ->
         raise Exit)
    }]
*)
val wait_errors : (unit -[!r async | !r]-> 'a)  -[!r async]-> ('a, unit) Result.t

(** [fold_errors f ~init ~on_error] calls [on_error] for every exception raised during the
    execution of [f]. This include exceptions raised when calling [f ()] or during the
    execution of fibers after [f ()] has returned.

    Exceptions raised by [on_error] are passed on to the parent error handler. *)
val fold_errors
  :  (unit -[!r async | !r]-> 'a)
  -> init:'b
  -> on_error:(exn -> 'b -> 'b)
  -[!r async]-> ('a, 'b) Result.t

(** [collect_errors f] is:

    {[
      fold_errors f
        ~init:[]
        ~on_error:(fun e l -> e :: l)
    ]}
*)
val collect_errors
  :  (unit -[!r async | !r]-> 'a)
  -[!r async]-> ('a, exn list) Result.t

(** [finalize f ~finally] runs [finally] after [f ()] has terminated,
    whether it fails or succeeds. *)
val finalize
  :  (unit -[!r async | !r]-> 'a)
  -> finally:(unit -[!r async]-> unit)
  -[!r async]-> 'a

(** {1 Synchronization} *)

(** Write once variables *)
module Ivar : sig
  (** A ivar is a synchronization variable that can be written only
      once. *)
  type 'a t

  (** Create a new empty ivar. *)
  val create : unit -> 'a t

  (** Read the contents of the ivar. *)
  val read : 'a t -[!r async]-> 'a

  (** Fill the ivar with the following value. This can only be called
      once for a given ivar. *)
  val fill : 'a t -> 'a -[!r async]-> unit
end

module Mutex : sig
  type t
  val create : unit -> t
  val with_lock : t ->> (unit -[!r async | !r]-> 'a) -[!r async]-> 'a
end

(** {1 Running fibers} *)

(** Wait for one iteration of the scheduler *)
val yield : unit -[!r async]-> unit

(** [run t] runs a fiber until it yield a result. If it becomes clear that the execution
    of the fiber will never terminate, raise [Never]. *)
val run : ('a -[!r async | !r]-> 'b) ->> 'a -[!r]-> 'b

exception Never
