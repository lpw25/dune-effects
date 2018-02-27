open Stdune

module Eq = struct
  type ('a, 'b) t = T : ('a, 'a) t

  let cast (type a) (type b) (T : (a, b) t) (x : a) : b = x
end

module Var0 = struct
  module Key = struct
    type 'a t = ..
  end

  module type T = sig
    type t
    type 'a Key.t += T : t Key.t
    val id : int
  end

  type 'a t = (module T with type t = 'a)

  let next = ref 0

  let create (type a) () =
    let n = !next in
    next := n + 1;
    let module M = struct
      type t = a
      type 'a Key.t += T : t Key.t
      let id = n
    end in
    (module M : T with type t = a)

  let id (type a) (module M : T with type t = a) = M.id

  let eq (type a) (type b)
        (module A : T with type t = a)
        (module B : T with type t = b) : (a, b) Eq.t =
    match A.T with
    | B.T -> Eq.T
    | _ -> assert false
end

module Binding = struct
  type t = T : 'a Var0.t * 'a -> t
end

module Int_map = Map.Make(Int)

module Handler = struct

  type 'a t = ('a, io, unit, global) continuation

end

module Task = struct

  type t = Task : 'a * 'a Handler.t -> t

end

module Execution_context : sig
  type t

  val create_initial : unit -> t
  val forward_error : t -> exn -> unit

  val add_refs : t -> int -> unit
  val deref : t -> unit

  (* Create a new context with a new referebce count. [on_release] is called when the
     context is no longer used. *)
  val create_sub
    :  t
    -> on_release:(unit -> unit)
    -> t

  val set_error_handler
    :  t
    -> on_error:(exn -> unit)
    -> t

  val vars : t -> Binding.t Int_map.t
  val set_vars : t -> Binding.t Int_map.t -> t

  val enqueue : t -> Task.t -> unit
  val schedule : t -> unit

end = struct
  type t =
    { on_error : exn -> unit (* This callback must never raise *)
    ; fibers   : int ref (* Number of fibers running in this execution
                            context *)
    ; vars     : Binding.t Int_map.t
    ; on_release : (t * unit Waiting.t) option
    ; suspended : Task.t Queue.t
    }

  let vars t = t.vars
  let set_vars t vars = { t with vars }

  let enqueue t s =
    Queue.push s t.suspended

  let schedule t =
    match Queue.pop t.suspended with
    | exception Queue.Empty -> ()
    | Task.Task(x, k) -> continue k x

  let create_initial () =
    { on_error   = reraise
    ; fibers     = ref 1
    ; vars       = Int_map.empty
    ; on_release = None
    ; suspended = Queue.create ()
    }

  let release () =
    match on_release with
    | None -> ()
    | Some(ctx, cont) -> enqueue ctx cont

  let add_refs t n = t.fibers := !(t.fibers) + n

  let deref t =
    let n = !(t.fibers) - 1 in
    assert (n >= 0);
    t.fibers := n;
    if n = 0 then release ()

  let forward_error t exn =
    let bt = Printexc.get_raw_backtrace () in
    try
      t.on_error exn
    with exn2 ->
      (* We can't abort the execution at this point, so we just dump
         the error on stderr *)
      let bt2 = Printexc.get_backtrace () in
      let s =
        (Printf.sprintf "%s\n%s\nOriginal exception was: %s\n%s"
           (Printexc.to_string exn2) bt2
           (Printexc.to_string exn) (Printexc.raw_backtrace_to_string bt))
        |> String.split_lines
        |> List.map ~f:(Printf.sprintf "| %s")
        |> String.concat ~sep:"\n"
      in
      let line = String.make 71 '-' in
      Format.eprintf
        "/%s\n\
         | @{<error>Internal error@}: \
         Fiber.Execution_context.forward_error: error handler raised.\n\
         %s\n\
         \\%s@."
        line s line

  let forward_error t exn =
    forward_error t exn;
    deref t

  let create_sub t ~on_release =
    { t with on_release; fibers = ref 1 }

  let set_error_handler t ~on_error =
    { t with on_error }

end

module Ctx = Execution_context

module Waiting = struct

  type 'a t =
    { ctx : Ctx.t; cont : 'a Handler.t }

  let activate t x =
    Ctx.enqueue t.ctx (Task(x, t.cont))

end

(*
let catch f ctx k =
  try
    f () ctx k
  with exn ->
    EC.forward_error ctx exn

type ('a, 'b) fork_and_join_state =
  | Nothing_yet
  | Got_a of 'a
  | Got_b of 'b

let fork_and_join fa fb ctx k =
  let state = ref Nothing_yet in
  EC.add_refs ctx 1;
  begin
    try
      fa () ctx (fun a ->
        match !state with
        | Nothing_yet -> EC.deref ctx; state := Got_a a
        | Got_a _ -> assert false
        | Got_b b -> k (a, b))
    with exn ->
      EC.forward_error ctx exn
  end;
  fb () ctx (fun b ->
    match !state with
    | Nothing_yet -> EC.deref ctx; state := Got_b b
    | Got_a a -> k (a, b)
    | Got_b _ -> assert false)

let fork_and_join_unit fa fb ctx k =
  let state = ref Nothing_yet in
  EC.add_refs ctx 1;
  begin
    try
      fa () ctx (fun () ->
        match !state with
        | Nothing_yet -> EC.deref ctx; state := Got_a ()
        | Got_a _ -> assert false
        | Got_b b -> k b)
    with exn ->
      EC.forward_error ctx exn
  end;
  fb () ctx (fun b ->
    match !state with
    | Nothing_yet -> EC.deref ctx; state := Got_b b
    | Got_a () -> k b
    | Got_b _ -> assert false)

let list_of_option_array =
  let rec loop arr i acc =
    if i = 0 then
      acc
    else
      let i = i - 1 in
      match arr.(i) with
      | None -> assert false
      | Some x ->
        loop arr i (x :: acc)
  in
  fun a -> loop a (Array.length a) []

let parallel_map l ~f ctx k =
  match l with
  | [] -> k []
  | [x] -> f x ctx (fun x -> k [x])
  | _ ->
    let n = List.length l in
    EC.add_refs ctx (n - 1);
    let left_over = ref n in
    let results = Array.make n None in
    List.iteri l ~f:(fun i x ->
      try
        f x ctx (fun y ->
          results.(i) <- Some y;
          decr left_over;
          if !left_over = 0 then
            k (list_of_option_array results)
          else
            EC.deref ctx)
      with exn ->
        EC.forward_error ctx exn)

let parallel_iter l ~f ctx k =
  match l with
  | [] -> k ()
  | [x] -> f x ctx k
  | _ ->
    let n = List.length l in
    EC.add_refs ctx (n - 1);
    let left_over = ref n in
    let k () =
      decr left_over;
      if !left_over = 0 then k () else EC.deref ctx
    in
    List.iter l ~f:(fun x ->
      try
        f x ctx k
      with exn ->
        EC.forward_error ctx exn)
*)
module Var1 = struct
  include Var0

  let get' var ctx k =
    match Int_map.find (Ctx.vars ctx) (id var) with
    | None -> continue k None
    | Some (Binding.T (var', v)) ->
      let eq = eq var' var in
      continue k (Some (Eq.cast eq v))

  let get_exn' var ctx k =
    match Int_map.find (Ctx.vars ctx) (id var) with
    | None -> discontinue k (Failure "Fiber.Var.find_exn")
    | Some (Binding.T (var', v)) ->
      let eq = eq var' var in
      continue k (Eq.cast eq v)

  let set' (type a) (var : a t) x f exec ctx k =
    let (module M) = var in
    let data = Binding.T (var, x) in
    let ctx' =
      Ctx.set_vars ctx (Int_map.add (Ctx.vars ctx) M.id data)
    in
    exec (fun () -> Ctx.enqueue ctx (Task(f (), k))) ctx' k

end
(*
let with_error_handler f ~on_error ctx k =
  let on_error exn =
    try
      on_error exn
    with exn ->
      (* Increase the ref-counter of the parent context since this error doesn't originate
         from a fiber and so doesn't change the number of running fibers. *)
      EC.add_refs ctx 1;
      EC.forward_error ctx exn
  in
  let ctx = EC.set_error_handler ctx ~on_error in
  try
    f () ctx k
  with exn ->
    EC.forward_error ctx exn

let wait_errors t ctx k =
  let result = ref (Result.Error ()) in
  let on_release () =
    try
      k !result
    with exn ->
      EC.forward_error ctx exn
  in
  let sub_ctx = EC.create_sub ctx ~on_release in
  t sub_ctx (fun x ->
    result := Ok x;
    EC.deref sub_ctx)

let fold_errors f ~init ~on_error =
  let acc = ref init in
  let on_error exn =
    acc := on_error exn !acc
  in
  wait_errors (with_error_handler f ~on_error)
  >>| function
  | Ok _ as ok -> ok
  | Error ()   -> Error !acc

let collect_errors f =
  fold_errors f
    ~init:[]
    ~on_error:(fun e l -> e :: l)

let finalize f ~finally =
  wait_errors (catch f) >>= fun res ->
  finally () >>= fun () ->
  match res with
  | Ok x -> return x
  | Error () -> never

*)

module Ivar0 = struct
  type 'a state =
    | Full  of 'a
    | Empty of 'a Waiting.t Queue.t

  type 'a t = { mutable state : 'a state }

  let create () = { state = Empty (Queue.create ()) }

  let fill' t x ctx k =
    match t.state with
    | Full  _ -> discontinue k (Failure "Fiber.Ivar.fill")
    | Empty q ->
      t.state <- Full x;
      Queue.iter
        (fun handler ->
           Waiting.activate handler x)
        q;
      Ctx.enqueue ctx (Task((), k));
      Ctx.schedule ctx

  let read' t ctx k =
    match t.state with
    | Full  x -> continue k x
    | Empty q ->
      Queue.push { Waiting. cont = k; ctx } q;
      Ctx.schedule ctx
end


module Future = struct
  type 'a t = 'a Ivar.t

  let wait = Ivar.read
end

(*
let fork f ctx k =
  let ivar = Ivar.create () in
  EC.add_refs ctx 1;
  begin
    try
      f () ctx (fun x -> Ivar.fill ivar x ctx ignore)
    with exn ->
      EC.forward_error ctx exn
  end;
  k ivar

let nfork_map l ~f ctx k =
  match l with
  | [] -> k []
  | [x] -> fork (fun () -> f x) ctx (fun ivar -> k [ivar])
  | l ->
    let n = List.length l in
    EC.add_refs ctx (n - 1);
    let ivars =
      List.map l ~f:(fun x ->
        let ivar = Ivar.create () in
        begin
          try
            f x ctx (fun x -> Ivar.fill ivar x ctx ignore)
          with exn ->
            EC.forward_error ctx exn
        end;
        ivar)
    in
    k ivars

let nfork l : _ Future.t list t = nfork_map l ~f:(fun f -> f ())

module Mutex = struct
  type t =
    { mutable locked  : bool
    ; mutable waiters : unit Handler.t Queue.t
    }

  let lock t ctx k =
    if t.locked then
      Queue.push { Handler. run = k; ctx } t.waiters
    else begin
      t.locked <- true;
      k ()
    end

  let unlock t _ctx k =
    assert t.locked;
    if Queue.is_empty t.waiters then
      t.locked <- false
    else
      Handler.run (Queue.pop t.waiters) ();
    k ()

  let with_lock t f =
    lock t >>= fun () ->
    finalize f ~finally:(fun () -> unlock t)

  let create () =
    { locked  = false
    ; waiters = Queue.create ()
    }
end

let suspended = ref []

exception Never

let run t =
  let result = ref None in
  let ctx = EC.create_initial () in
  begin
    try
      t ctx (fun x -> result := Some x)
    with exn ->
      EC.forward_error ctx exn
  end;
  let rec loop () =
    match !result with
    | Some x -> x
    | None ->
      match List.rev !suspended with
      | [] -> raise Never
      | to_run ->
        suspended := [];
        List.iter to_run ~f:(fun h -> Handler.run h ());
        loop ()
  in
  loop ()
*)

let rec exec ctx f x =
  match f x with
  | () -> Ctx.schdeule ctx
  | effect Yield(), k ->
    Ctx.enqueue ctx (Task((), k));
    Ctx.schedule ctx
  | effect Fill(ivar, x), k ->
    Ivar0.fill' ivar x ctx k
  | effect Read(ivar), k ->
    Ivar0.read' ivar ctx k
  | effect Get(var), k ->
    Var1.get' var ctx k
  | effect Get_exn(var), k ->
    Var1.get_exn' var ctx k
  | effect Set(var, f), k ->
    Var1.set' var f exec ctx k

let run f x =
  let result = ref None in
  let ctx = Ctx.create_initial () in
  exec ctx (fun x -> result := Some (f x)) x;
  match !result with
  | None -> assert false
  | Some res -> res

type 'a op =
  | Yield : unit op
  | Fill : 'b Ivar0.t * 'b -> unit op
  | Read : 'a Ivar0.t -> 'a op
  | Get : 'a Var0.t -> 'a option op
  | Get_exn : 'a Var0.t -> 'a op
  | Set : 'a Var0.t * 'a * (unit -[async]-> 'b) -> 'b op

and effect async = ![ Async : 'a op -> 'a ]

module Ivar = struct

  include Ivar0

  let fill t x = perform Async(Fill(t, x))

  let read t = perform Async(Read t)

end

module Var = struct

  include Var1

  let get t = perform Async(Get t)

  let get_exn t = perform Async(Get_exn t)

  let set t x f = perform Async(Set(t, x, f)

end
