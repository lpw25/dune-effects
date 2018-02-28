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

type !r ctx =
  { on_error : exn -> unit; (* This callback must never raise *)
    fibers   : int ref; (* Number of fibers running in this execution
                            context *)
    vars     : Binding.t Int_map.t;
    on_release : (t * unit waiting) option;
    suspended : !r task Queue.t; }

and ('a, !r) cont =
  ('a, !r, unit, global) continuation

and !r task =
  | Cont : 'a * ('a, !r) cont -> task
  | Cont_unit : (unit, !r) cont -> task
  | Finish : 'a * ('a -[!r async | !r]-> 'b) * 'b ivar -> task

and 'a waiting =
    Waiting : !r ctx * ('a, !r) cont -> 'a waiting

and 'a ivar_state =
  | Full  of 'a
  | Empty of 'a waiting Queue.t

and 'a ivar = { mutable state : 'a ivar_state }

and mutex =
  { mutable locked  : bool;
    mutable waiters : unit Waiting.t Queue.t; }

and ('a, !r) op =
  | Fill : 'b ivar * 'b -> (unit, !r) op
  | Read : 'a ivar -> ('a, !r) op
  | Get : 'a Var0.t -> ('a option, !r) op
  | Get_exn : 'a Var0.t -> ('a, !r) op
  | Set : 'a Var0.t * 'a * (unit -[!r async | !r]-> 'b) -> ('b, !r) op
  | Lock : mutex -> (unit, !r) op
  | Unlock : mutex -> (unit, !r) op
  | Fork : 'a * ('a -[!r async | !r]-> 'b) -> ('b ivar, !r) op
  | NFork : 'a list * ('a -[!r async | !r]-> 'b) -> ('b ivar list, !r) op
  | Fork_and_join :
      (unit -[!r async | !r]-> 'a) ->
      (unit -[!r async | !r]-> 'b) ->
      ('a * 'b, !r) op
  | Parallel_map : 'a list * ('a -[!r async | !r]-> 'b) -> ('b list, !r) op
  | Parallel_iter : 'a list * ('a -[!r async | !r]-> unit) -> (unit, !r) op
  | Yield : (unit, !r) op
  | With_error_handler : (unit -[!r async | !r]-> 'a) -> (exn -> unit) -> 'a op
  | Wait_errors : (unit -[!r async | !r]-> 'a) -> 'a op

and effect !r async = ![ Async : ('a, !r) op -> 'a ]

module Ctx = struct

  type t = ctx

  let vars t = t.vars
  let set_vars t vars = { t with vars }

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

let enqueue t s =
  Queue.push s t.suspended

let activate (Waiting(ctx, cont)) x =
  enqueue ctx (Cont(x, cont))

let rec schedule ctx =
  match Queue.pop ctx.suspended with
  | exception Queue.Empty -> ()
  | Cont(x, k) -> continue k x
  | Cont_unit k -> continue k ()
  | Finish(x, f, ivar) -> exec ctx (fun x -> finish ivar (f x)) x

and fill ivar x ctx k =
  match ivar.state with
  | Full  _ -> discontinue k (Failure "Fiber.Ivar.fill")
  | Empty q ->
    ivar.state <- Full x;
    Queue.iter
      (fun handler ->
         Waiting.activate handler x)
      q;
    enqueue ctx (Cont_unit(k));
    schedule ctx

and read ivar ctx k =
  match ivar.state with
  | Full  x -> continue k x
  | Empty q ->
    Queue.push { Waiting. cont = k; ctx } q;
    schedule ctx

and get var ctx k =
  match Int_map.find (Ctx.vars ctx) (id var) with
  | None -> continue k None
  | Some (Binding.T (var', v)) ->
    let eq = eq var' var in
    continue k (Some (Eq.cast eq v))

and get_exn var ctx k =
  match Int_map.find (Ctx.vars ctx) (id var) with
  | None -> discontinue k (Failure "Fiber.Var.find_exn")
  | Some (Binding.T (var', v)) ->
    let eq = eq var' var in
    continue k (Eq.cast eq v)

and set (type a) (var : a t) x f ctx k =
  let (module M) = var in
  let data = Binding.T (var, x) in
  let ctx' =
    Ctx.set_vars ctx (Int_map.add (Ctx.vars ctx) M.id data)
  in
  exec ctx' (fun () -> enqueue ctx (Cont(f (), k))) ()

and lock lock ctx k =
  if lock.locked then
    Queue.push (Waiting(ctx, k)) lock.waiters;
    schedule ctx
  else begin
    lock.locked <- true;
    continue k ()
  end

and unlock lock _ctx k =
  assert lock.locked;
  if Queue.is_empty lock.waiters then begin
    lock.locked <- false
  end else begin
    activate (Queue.pop lock.waiters)
  end;
  continue k ()

and finish ivar x =
  match ivar.state with
  | Full  _ -> assert false
  | Empty q ->
    ivar.state <- Full x;
    Queue.iter
      (fun handler ->
         Waiting.activate handler x)
      q

and fork f x ctx k =
  let ivar = { state = Empty (Queue.create ()) } in
  Ctx.add_refs ctx 1;
  enqueue ctx (Cont(ivar, k));
  exec ctx (fun x -> finish ivar (f x)) x

and nfork l f ctx k =
  match l with
  | [] -> continue k []
  | [x] ->
    let ivar = { state = Empty (Queue.create ()) } in
    Ctx.add_refs ctx 1;
    enqueue ctx (Cont(ivar, k));
    exec ctx (fun x -> finish ivar [f x]) x
  | first :: rest ->
    let n = List.length rest in
    Ctx.add_refs ctx n;
    let rest_ivars =
      List.map rest ~f:(fun x ->
        let ivar = { state = Empty (Queue.create ()) } in
        enqueue ctx (Finish(x, f, ivar));
        ivar)
    in
    let first_ivar = { state = Empty (Queue.create ()) } in
    let ivars = first_ivar :: rest_ivars in
    enqueue ctx (Cont(ivars, k));
    exec ctx (fun x -> finish ivar (f x)) x

  | Fork_and_join :
      (unit -[!r async | !r]-> 'a) ->
      (unit -[!r async | !r]-> 'b) ->
      ('a * 'b, !r) op
  | Parallel_map : 'a list * ('a -[!r async | !r]-> 'b) -> ('b list, !r) op
  | Parallel_iter : 'a list * ('a -[!r async | !r]-> unit) -> (unit, !r) op

and yield ctx k =
  enqueue ctx (Cont_unit(k));
  schedule ctx

  | With_error_handler : (unit -[!r async | !r]-> 'a) -> (exn -> unit) -> 'a op
  | Wait_errors : (unit -[!r async | !r]-> 'a) -> 'a op

and exec ctx f x =
  match f x with
  | () -> schdeule ctx
  | effect Async(Yield), k -> yield ctx k
  | effect Async(Fill(ivar, x)), k -> fill ivar x ctx k
  | effect Async(Read ivar), k -> read ivar ctx k
  | effect Async(Get var), k -> get var ctx k
  | effect Async(Get_exn var), k -> get_exn var ctx k
  | effect Async(Set(var, f)), k -> set var f exec ctx k
  | exception exn -> Ctx.forward_error ctx exn


type ('a, 'b) fork_and_join_state =
  | Nothing_yet
  | Got_a of 'a
  | Got_b of 'b

(*
let catch f ctx k =
  try
    f () ctx k
  with exn ->
    EC.forward_error ctx exn

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

*)


(*
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

  

end


module Future = struct
  type 'a t = 'a Ivar.t

  let wait = Ivar.read
end

(*
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

let run f x =
  let result = ref None in
  let ctx = Ctx.create_initial () in
  exec ctx (fun x -> result := Some (f x)) x;
  match !result with
  | None -> assert false
  | Some res -> res

module Ivar = struct

  type t = ivar

  let create () = { state = Empty (Queue.create ()) }

  let fill t x = perform Async(Fill(t, x))

  let read t = perform Async(Read t)

end

module Var = struct

  type t = Var0.t

  let create = Var0.create

  let get t = perform Async(Get t)

  let get_exn t = perform Async(Get_exn t)

  let set t x f = perform Async(Set(t, x, f)

end
