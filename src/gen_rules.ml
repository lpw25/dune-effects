open Import
open Jbuild
open Build.O
open! No_io

(* +-----------------------------------------------------------------+
   | Utils                                                           |
   +-----------------------------------------------------------------+ *)

module type Params = sig
  val sctx : Super_context.t
end

module Gen(P : Params) = struct
  module Alias = Build_system.Alias
  module SC = Super_context
  open P

  let ctx = SC.context sctx

  let stanzas_per_dir =
    List.map (SC.stanzas sctx) ~f:(fun stanzas ->
      (stanzas.SC.Dir_with_jbuild.ctx_dir, stanzas))
    |> Path.Map.of_list_exn

  (* +-----------------------------------------------------------------+
     | Interpretation of [modules] fields                              |
     +-----------------------------------------------------------------+ *)

  module Eval_modules = Ordered_set_lang.Make(struct
      type t = (Module.t, string * Loc.t) result
      let name = function
        | Error (s, _) -> s
        | Ok m -> Module.name m
    end)

  let parse_modules ~(all_modules : Module.t String_map.t) ~buildable =
    let conf : Buildable.t = buildable in
    let standard_modules = String_map.map all_modules ~f:(fun m -> Ok m) in
    let fake_modules = ref String_map.empty in
    let parse ~loc s =
      let s = String.capitalize s in
      match String_map.find all_modules s with
      | Some m -> Ok m
      | None ->
        fake_modules := String_map.add !fake_modules s loc;
        Error (s, loc)
    in
    let modules =
      Eval_modules.eval_unordered
        conf.modules
        ~parse
        ~standard:standard_modules
    in
    let only_present_modules modules =
      String_map.filter_map ~f:(function
        | Ok m -> Some m
        | Error (s, loc) -> Loc.fail loc "Module %s doesn't exist." s
      ) modules
    in
    let modules = only_present_modules modules in
    let intf_only =
      Eval_modules.eval_unordered
        conf.modules_without_implementation
        ~parse
        ~standard:String_map.empty
    in
    let intf_only = only_present_modules intf_only in
    String_map.iteri !fake_modules ~f:(fun m loc ->
      Loc.warn loc "Module %s is excluded but it doesn't exist." m
    );
    let real_intf_only =
      String_map.filter modules
        ~f:(fun (m : Module.t) -> Option.is_none m.impl)
    in
    if String_map.equal intf_only real_intf_only
         ~equal:(fun a b -> Module.name a = Module.name b) then
      modules
    else begin
      let should_be_listed, shouldn't_be_listed =
        String_map.merge intf_only real_intf_only ~f:(fun name x y ->
          match x, y with
          | Some _, Some _ -> None
          | None  , Some _ -> Some (Left  (String.uncapitalize name))
          | Some _, None   -> Some (Right (String.uncapitalize name))
          | None  , None   -> assert false)
        |> String_map.values
        |> List.partition_map ~f:(fun x -> x)
      in
      let list_modules l =
        String.concat ~sep:"\n" (List.map l ~f:(sprintf "- %s"))
      in
      if should_be_listed <> [] then begin
        match Ordered_set_lang.loc conf.modules_without_implementation with
        | None ->
          Loc.warn conf.loc
            "Some modules don't have an implementation.\
             \nYou need to add the following field to this stanza:\
             \n\
             \n  %s\
             \n\
             \nThis will become an error in the future."
            (let tag = Sexp.unsafe_atom_of_string
                       "modules_without_implementation" in
             Sexp.to_string (List [ tag
                                  ; Sexp.To_sexp.(list string) should_be_listed
                                  ]))
        | Some loc ->
          Loc.warn loc
            "The following modules must be listed here as they don't \
             have an implementation:\n\
             %s\n\
             This will become an error in the future."
            (list_modules should_be_listed)
      end;
      if shouldn't_be_listed <> [] then begin
        (* Re-evaluate conf.modules_without_implementation but this
           time keep locations *)
        let module Eval =
          Ordered_set_lang.Make(struct
            type t = Loc.t * Module.t
            let name (_, m) = Module.name m
          end)
        in
        let parse ~loc s =
          let s = String.capitalize s in
          match String_map.find all_modules s with
          | Some m -> m
          | None -> Loc.fail loc "Module %s doesn't exist." s
        in
        let parse ~loc s = (loc, parse ~loc s) in
        let shouldn't_be_listed =
          Eval.eval_unordered conf.modules_without_implementation
            ~parse
            ~standard:(String_map.map all_modules ~f:(fun m -> (Loc.none, m)))
          |> String_map.values
          |> List.filter ~f:(fun (_, (m : Module.t)) ->
            Option.is_some m.impl)
        in
        (* CR-soon jdimino for jdimino: report all errors *)
        let loc, m = List.hd shouldn't_be_listed in
        Loc.fail loc
          "Module %s has an implementation, it cannot be listed here"
          m.name
      end;
      modules
    end

  (* +-----------------------------------------------------------------+
     | User rules & copy files                                         |
     +-----------------------------------------------------------------+ *)

  let interpret_locks ~dir ~scope locks =
    List.map locks ~f:(fun s ->
      Path.relative dir (SC.expand_vars sctx ~dir ~scope s))

  let user_rule (rule : Rule.t) ~dir ~scope =
    let targets : SC.Action.targets =
      match rule.targets with
      | Infer -> Infer
      | Static fns -> Static (List.map fns ~f:(Path.relative dir))
    in
    SC.add_rule_get_targets sctx ~mode:rule.mode ~loc:rule.loc
      ~locks:(interpret_locks ~dir ~scope rule.locks)
      (SC.Deps.interpret sctx ~scope ~dir rule.deps
       >>>
       SC.Action.run
         sctx
         rule.action
         ~dir
         ~dep_kind:Required
         ~targets
         ~scope)

  let copy_files_rules (def: Copy_files.t) ~src_dir ~dir ~scope =
    let loc = String_with_vars.loc def.glob in
    let glob_in_src =
      let src_glob = SC.expand_vars sctx ~dir def.glob ~scope in
      Path.relative src_dir src_glob ~error_loc:loc
    in
    (* The following condition is required for merlin to work.
       Additionally, the order in which the rules are evaluated only
       ensures that [sources_and_targets_known_so_far] returns the
       right answer for sub-directories only. *)
    if not (Path.is_descendant glob_in_src ~of_:src_dir) then
      Loc.fail loc "%s is not a sub-directory of %s"
        (Path.to_string_maybe_quoted glob_in_src) (Path.to_string_maybe_quoted src_dir);
    let glob = Path.basename glob_in_src in
    let src_in_src = Path.parent glob_in_src in
    let re =
      match Glob_lexer.parse_string glob with
      | Ok re ->
        Re.compile re
      | Error (_pos, msg) ->
        Loc.fail (String_with_vars.loc def.glob) "invalid glob: %s" msg
    in
    (* add rules *)
    let src_in_build = Path.append ctx.build_dir src_in_src in
    let files = SC.eval_glob sctx ~dir:src_in_build re in
    List.map files ~f:(fun basename ->
      let file_src = Path.relative src_in_build basename in
      let file_dst = Path.relative dir basename in
      SC.add_rule sctx
        ((if def.add_line_directive
          then Build.copy_and_add_line_directive
          else Build.copy)
           ~src:file_src
           ~dst:file_dst);
      file_dst)

  (* +-----------------------------------------------------------------+
     | "text" file listing                                             |
     +-----------------------------------------------------------------+ *)

  (* Compute the list of "text" files (.ml, .c, ...). This is the list
     of source files + user generated ones. As a side-effect, setup
     user rules and copy_files rules. *)
  let text_files =
    let cache = Hashtbl.create 32 in
    fun ~dir ->
      Hashtbl.find_or_add cache dir ~f:(fun dir ->
        match Path.Map.find stanzas_per_dir dir with
        | None -> String_set.empty
        | Some { stanzas; src_dir; scope; _ } ->
          (* Interpret a few stanzas in order to determine the list of
             files generated by the user. *)
          let generated_files =
            List.concat_map stanzas ~f:(fun stanza ->
              match (stanza : Stanza.t) with
              | Rule rule ->
                List.map (user_rule rule  ~dir ~scope) ~f:Path.basename
              | Copy_files def ->
                List.map (copy_files_rules def ~src_dir ~dir ~scope)
                  ~f:Path.basename
              | Library { buildable; _ } | Executables { buildable; _ } ->
                (* Manually add files generated by the (select ...)
                   dependencies *)
                List.filter_map buildable.libraries ~f:(fun dep ->
                  match (dep : Jbuild.Lib_dep.t) with
                  | Direct _ -> None
                  | Select s -> Some s.result_fn)
              | Alias _ | Provides _ | Install _ -> [])
            |> String_set.of_list
          in
          String_set.union generated_files
            (SC.source_files sctx ~src_path:src_dir))

  (* +-----------------------------------------------------------------+
     | Modules listing                                                 |
     +-----------------------------------------------------------------+ *)

  let guess_modules ~dir ~files =
    let impl_files, intf_files =
      String_set.to_list files
      |> List.filter_partition_map ~f:(fun fn ->
        (* we aren't using Filename.extension because we want to handle
           filenames such as foo.cppo.ml *)
        match String.lsplit2 fn ~on:'.' with
        | Some (_, "ml") -> Left { Module.File.syntax=OCaml ; name=fn }
        | Some (_, "re") -> Left { Module.File.syntax=Reason ; name=fn }
        | Some (_, "mli") -> Right { Module.File.syntax=OCaml ; name=fn }
        | Some (_, "rei") -> Right { Module.File.syntax=Reason ; name=fn }
        | _ -> Skip)
    in
    let parse_one_set files =
      List.map files ~f:(fun (f : Module.File.t) ->
        (String.capitalize (Filename.chop_extension f.name), f))
      |> String_map.of_list
      |> function
      | Ok x -> x
      | Error (name, f1, f2) ->
        let src_dir = Path.drop_build_context_exn dir in
        die "too many files for module %s in %s: %s and %s"
          name (Path.to_string src_dir) f1.name f2.name
    in
    let impls = parse_one_set impl_files in
    let intfs = parse_one_set intf_files in
    String_map.merge impls intfs ~f:(fun name impl intf ->
      Some
        { Module.name
        ; impl
        ; intf
        ; obj_name = ""
        }
    )

  let modules_by_dir =
    let cache = Hashtbl.create 32 in
    fun ~dir ->
      Hashtbl.find_or_add cache dir ~f:(fun dir ->
        let files = text_files ~dir in
        guess_modules ~dir ~files)

  type modules_by_lib =
    { modules          : Module.t String_map.t
    ; alias_module     : Module.t option
    ; main_module_name : string
    }

  let modules_by_lib =
    let cache = Hashtbl.create 32 in
    fun (lib : Library.t) ~dir ->
      Hashtbl.find_or_add cache (dir, lib.name) ~f:(fun _ ->
        let all_modules = modules_by_dir ~dir in
        let modules =
          parse_modules ~all_modules ~buildable:lib.buildable
        in
        let main_module_name = String.capitalize lib.name in
        let modules =
          String_map.map modules ~f:(fun (m : Module.t) ->
            let wrapper =
              if not lib.wrapped || m.name = main_module_name then
                None
              else
                Some lib.name
            in
            Module.set_obj_name m ~wrapper)
        in
        let alias_module =
          if not lib.wrapped ||
             (String_map.cardinal modules = 1 &&
              String_map.mem modules main_module_name) then
            None
          else if String_map.mem modules main_module_name then
            let file ext =
              Some { Module.File.
                     name   = sprintf "%s__%s-gen" lib.name ext
                   ; syntax = OCaml
                   }
            in
            (* The tests don't pass with 4.02 if we don't do that *)
            let needs_impl = ctx.version < (4, 03, 0) in
            Some
              { Module.name = main_module_name ^ "__"
              ; impl = if     needs_impl then file ".ml"  else None
              ; intf = if not needs_impl then file ".mli" else None
              ; obj_name = lib.name ^ "__"
              }
          else
            Some
              { Module.name = main_module_name
              ; impl = Some { name   = lib.name ^ ".ml-gen"
                            ; syntax = OCaml
                            }
              ; intf = None
              ; obj_name = lib.name
              }
        in
        { modules; alias_module; main_module_name })

  let module_names_of_lib lib ~dir =
    let { modules; alias_module; _ } = modules_by_lib lib ~dir in
    let modules =
      match alias_module with
      | None -> modules
      | Some m -> String_map.add modules m.name m
    in
    String_map.values modules

  (* +-----------------------------------------------------------------+
     | Library stuff                                                   |
     +-----------------------------------------------------------------+ *)

  let lib_archive (lib : Library.t) ~dir ~ext = Path.relative dir (lib.name ^ ext)

  let stubs_archive lib ~dir =
    Library.stubs_archive lib ~dir ~ext_lib:ctx.ext_lib

  let dll (lib : Library.t) ~dir =
    Path.relative dir (sprintf "dll%s_stubs%s" lib.name ctx.ext_dll)

  let msvc_hack_cclibs cclibs =
    let f lib =
      if String.is_prefix lib ~prefix:"-l" then
        String.sub lib ~pos:2 ~len:(String.length lib - 2) ^ ".lib"
      else
        lib
    in
    let cclibs = List.map cclibs ~f in
    let f lib =
      if String.is_prefix lib ~prefix:"-l" then
        String.sub lib ~pos:2 ~len:(String.length lib - 2)
      else
        lib
    in
    List.map cclibs ~f

  let build_lib (lib : Library.t) ~scope ~flags ~dir ~obj_dir ~mode
        ~top_sorted_modules =
    Option.iter (Context.compiler ctx mode) ~f:(fun compiler ->
      let target = lib_archive lib ~dir ~ext:(Mode.compiled_lib_ext mode) in
      let stubs_flags =
        if not (Library.has_stubs lib) then
          []
        else
          let stubs_name = lib.name ^ "_stubs" in
          match mode with
          | Byte -> ["-dllib"; "-l" ^ stubs_name; "-cclib"; "-l" ^ stubs_name]
          | Native -> ["-cclib"; "-l" ^ stubs_name]
      in
      let map_cclibs =
        (* https://github.com/ocaml/dune/issues/119 *)
        if ctx.ccomp_type = "msvc" then
          msvc_hack_cclibs
        else
          fun x -> x
      in
      let artifacts ~ext modules =
        List.map modules ~f:(Module.obj_file ~obj_dir ~ext)
      in
      let register_native_objs_deps build =
        match mode with
        | Byte   -> build
        | Native ->
          build >>>
          Build.dyn_paths (Build.arr (artifacts ~ext:ctx.ext_obj))
      in
      SC.add_rule sctx
        (Build.fanout4
           (register_native_objs_deps top_sorted_modules
            >>^ artifacts ~ext:(Cm_kind.ext (Mode.cm_kind mode)))
           (SC.expand_and_eval_set sctx ~scope ~dir lib.c_library_flags ~standard:[])
           (Ocaml_flags.get flags mode)
           (SC.expand_and_eval_set sctx ~scope ~dir lib.library_flags ~standard:[])
         >>>
         Build.run ~context:ctx (Ok compiler)
           ~extra_targets:(
             match mode with
             | Byte -> []
             | Native -> [lib_archive lib ~dir ~ext:ctx.ext_lib])
           [ Dyn (fun (_, _, flags, _) -> As flags)
           ; A "-a"; A "-o"; Target target
           ; As stubs_flags
           ; Dyn (fun (_, cclibs, _, _) -> Arg_spec.quote_args "-cclib" (map_cclibs cclibs))
           ; Dyn (fun (_, _, _, library_flags) -> As library_flags)
           ; As (match lib.kind with
               | Normal -> []
               | Ppx_deriver | Ppx_rewriter -> ["-linkall"])
           ; Dyn (fun (cm_files, _, _, _) -> Deps cm_files)
           ]))

  let build_c_file (lib : Library.t) ~scope ~dir ~requires ~h_files c_name =
    let src = Path.relative dir (c_name ^ ".c") in
    let dst = Path.relative dir (c_name ^ ctx.ext_obj) in
    SC.add_rule sctx
      (Build.paths h_files
       >>>
       Build.fanout
         (SC.expand_and_eval_set sctx ~scope ~dir lib.c_flags ~standard:(Context.cc_g ctx))
         requires
       >>>
       Build.run ~context:ctx
         (* We have to execute the rule in the library directory as the .o is produced in
            the current directory *)
         ~dir
         (Ok ctx.ocamlc)
         [ As (Utils.g ())
         ; Dyn (fun (c_flags, libs) ->
             S [ Lib.L.c_include_flags libs ~stdlib_dir:ctx.stdlib_dir
               ; Arg_spec.quote_args "-ccopt" c_flags
               ])
         ; A "-o"; Target dst
         ; Dep src
         ]);
    dst

  let build_cxx_file (lib : Library.t) ~scope ~dir ~requires ~h_files c_name =
    let src = Path.relative dir (c_name ^ ".cpp") in
    let dst = Path.relative dir (c_name ^ ctx.ext_obj) in
    let open Arg_spec in
    let output_param =
      if ctx.ccomp_type = "msvc" then
        [Concat ("", [A "/Fo"; Target dst])]
      else
        [A "-o"; Target dst]
    in
    SC.add_rule sctx
      (Build.paths h_files
       >>>
       Build.fanout
         (SC.expand_and_eval_set sctx ~scope ~dir lib.cxx_flags ~standard:(Context.cc_g ctx))
         requires
       >>>
       Build.run ~context:ctx
         (* We have to execute the rule in the library directory as the .o is produced in
            the current directory *)
         ~dir
         (SC.resolve_program sctx ctx.c_compiler)
         ([ S [A "-I"; Path ctx.stdlib_dir]
          ; As (SC.cxx_flags sctx)
          ; Dyn (fun (cxx_flags, libs) ->
              S [ Lib.L.c_include_flags libs ~stdlib_dir:ctx.stdlib_dir
                ; As cxx_flags
                ])
          ] @ output_param @
          [ A "-c"; Dep src
          ]));
    dst

  (* In 4.02, the compiler reads the cmi for module alias even with [-w -49
     -no-alias-deps], so we must sandbox the build of the alias module since the modules
     it references are built after. *)
  let alias_module_build_sandbox = ctx.version < (4, 03, 0)

  let library_rules (lib : Library.t) ~modules_partitioner ~dir ~files ~scope =
    let obj_dir = Utils.library_object_directory ~dir lib.name in
    let dep_kind = if lib.optional then Build.Optional else Required in
    let flags = Ocaml_flags.make lib.buildable sctx ~scope ~dir in
    let { modules; main_module_name; alias_module } = modules_by_lib ~dir lib in
    let source_modules = modules in
    let already_used =
      Modules_partitioner.acknowledge modules_partitioner
        ~loc:lib.buildable.loc ~modules
    in
    (* Preprocess before adding the alias module as it doesn't need
       preprocessing *)
    let modules =
      SC.PP.pp_and_lint_modules sctx ~dir ~dep_kind ~modules ~scope
        ~preprocess:lib.buildable.preprocess
        ~preprocessor_deps:
          (SC.Deps.interpret sctx ~scope ~dir
             lib.buildable.preprocessor_deps)
        ~lint:lib.buildable.lint
        ~lib_name:(Some lib.name)
    in

    let modules =
      match alias_module with
      | None -> modules
      | Some m -> String_map.add modules m.name m
    in

    let dep_graphs =
      Ocamldep.rules sctx ~dir ~modules ~already_used ~alias_module
        ~lib_interface_module:(if lib.wrapped then
                                 String_map.find modules main_module_name
                               else
                                 None)
    in

    Option.iter alias_module ~f:(fun m ->
      let file =
        match m.impl with
        | Some f -> f
        | None -> Option.value_exn m.intf
      in
      SC.add_rule sctx
        (Build.return
           (String_map.values (String_map.remove modules m.name)
            |> List.map ~f:(fun (m : Module.t) ->
              sprintf "(** @canonical %s.%s *)\n\
                       module %s = %s\n"
                main_module_name m.name
                m.name (Module.real_unit_name m))
            |> String.concat ~sep:"\n")
         >>> Build.write_file_dyn (Path.relative dir file.name)));

    let compile_info = Lib.DB.get_compile_info (Scope.libs scope) lib.name in
    let requires, real_requires =
      SC.Libs.requires sctx compile_info
        ~dir ~has_dot_merlin:true
    in

    let dynlink = lib.dynlink in
    let js_of_ocaml = lib.buildable.js_of_ocaml in
    Module_compilation.build_modules sctx
      ~js_of_ocaml ~dynlink ~flags ~scope ~dir ~obj_dir ~dep_graphs
      ~modules ~requires ~alias_module;
    Option.iter alias_module ~f:(fun m ->
      let flags = Ocaml_flags.default () in
      Module_compilation.build_module sctx m
        ~js_of_ocaml
        ~dynlink
        ~sandbox:alias_module_build_sandbox
        ~flags:(Ocaml_flags.append_common flags ["-w"; "-49"])
        ~scope
        ~dir
        ~obj_dir
        ~dep_graphs:(Ocamldep.Dep_graphs.dummy m)
        ~requires:(
          let requires =
            if String_map.is_empty modules then
              (* Just so that we setup lib dependencies for empty libraries *)
              requires
            else
              Build.return []
          in
          Cm_kind.Dict.of_func (fun ~cm_kind:_ -> requires))
        ~alias_module:None);

    if Library.has_stubs lib then begin
      let h_files =
        String_set.to_list files
        |> List.filter_map ~f:(fun fn ->
          if String.is_suffix fn ~suffix:".h" then
            Some (Path.relative dir fn)
          else
            None)
      in
      let o_files =
        let requires =
          Build.memoize "header files"
            (requires >>> SC.Libs.file_deps sctx ~ext:".h")
        in
        List.map lib.c_names ~f:(
          build_c_file   lib ~scope ~dir ~requires ~h_files
        ) @ List.map lib.cxx_names ~f:(
          build_cxx_file lib ~scope ~dir ~requires ~h_files
        )
      in
      match lib.self_build_stubs_archive with
      | Some _ -> ()
      | None ->
        let ocamlmklib ~sandbox ~custom ~targets =
          SC.add_rule sctx ~sandbox
            (SC.expand_and_eval_set sctx ~scope ~dir
               lib.c_library_flags ~standard:[]
             >>>
             Build.run ~context:ctx
               ~extra_targets:targets
               (Ok ctx.ocamlmklib)
               [ As (Utils.g ())
               ; if custom then A "-custom" else As []
               ; A "-o"
               ; Path (Path.relative dir (sprintf "%s_stubs" lib.name))
               ; Deps o_files
               ; Dyn (fun cclibs ->
                   (* https://github.com/ocaml/dune/issues/119 *)
                   if ctx.ccomp_type = "msvc" then
                     let cclibs = msvc_hack_cclibs cclibs in
                     Arg_spec.quote_args "-ldopt" cclibs
                   else
                     As cclibs
                 )
               ])
        in
        let static = stubs_archive lib ~dir in
        let dynamic = dll lib ~dir in
        if lib.modes.native &&
           lib.modes.byte   &&
           lib.dynlink
        then begin
          (* If we build for both modes and support dynlink, use a single invocation to
             build both the static and dynamic libraries *)
          ocamlmklib ~sandbox:false ~custom:false ~targets:[static; dynamic]
        end else begin
          ocamlmklib ~sandbox:false ~custom:true ~targets:[static];
          (* We can't tell ocamlmklib to build only the dll, so we sandbox the action to
             avoid overriding the static archive *)
          ocamlmklib ~sandbox:true ~custom:false ~targets:[dynamic]
        end
    end;

    List.iter Cm_kind.all ~f:(fun cm_kind ->
      let files =
        String_map.fold modules ~init:[] ~f:(fun m acc ->
          match Module.cm_file m ~obj_dir cm_kind with
          | None -> acc
          | Some fn -> fn :: acc)
      in
      SC.Libs.setup_file_deps_alias sctx ~dir lib ~ext:(Cm_kind.ext cm_kind)
        files);
    SC.Libs.setup_file_deps_group_alias sctx ~dir lib ~exts:[".cmi"; ".cmx"];
    SC.Libs.setup_file_deps_alias sctx ~dir lib ~ext:".h"
      (List.map lib.install_c_headers ~f:(fun header ->
         Path.relative dir (header ^ ".h")));

    let top_sorted_modules =
      Ocamldep.Dep_graph.top_closed_implementations dep_graphs.impl
        (String_map.values modules)
    in
    List.iter Mode.all ~f:(fun mode ->
      build_lib lib ~scope ~flags ~dir ~obj_dir ~mode ~top_sorted_modules);
    (* Build *.cma.js *)
    SC.add_rules sctx (
      let src = lib_archive lib ~dir ~ext:(Mode.compiled_lib_ext Mode.Byte) in
      let target = Path.extend_basename src ~suffix:".js" in
      Js_of_ocaml_rules.build_cm sctx ~scope ~dir
        ~js_of_ocaml:lib.buildable.js_of_ocaml ~src ~target);

    if ctx.natdynlink_supported then
      Option.iter ctx.ocamlopt ~f:(fun ocamlopt ->
        let src = lib_archive lib ~dir ~ext:(Mode.compiled_lib_ext Native) in
        let dst = lib_archive lib ~dir ~ext:".cmxs" in
        let build =
          Build.dyn_paths (Build.arr (fun () -> [lib_archive lib ~dir ~ext:ctx.ext_lib]))
          >>>
          Ocaml_flags.get flags Native
          >>>
          Build.run ~context:ctx
            (Ok ocamlopt)
            [ Dyn (fun flags -> As flags)
            ; A "-shared"; A "-linkall"
            ; A "-I"; Path dir
            ; A "-o"; Target dst
            ; Dep src
            ]
        in
        let build =
          if Library.has_stubs lib then
            Build.path (stubs_archive ~dir lib)
            >>>
            build
          else
            build
        in
        SC.add_rule sctx build
      );

    (* Odoc *)
    let mld_files =
      String_set.fold files ~init:[] ~f:(fun fn acc ->
        if Filename.check_suffix fn ".mld" then fn :: acc else acc)
    in
    Odoc.setup_library_rules sctx lib ~dir ~requires ~modules ~dep_graphs
      ~mld_files ~scope
    ;

    let flags =
      match alias_module with
      | None -> Ocaml_flags.common flags
      | Some m ->
        Ocaml_flags.prepend_common ["-open"; m.name] flags
        |> Ocaml_flags.common
    in

    Sub_system.gen_rules
      { super_context = sctx
      ; dir
      ; stanza = lib
      ; scope
      ; source_modules
      ; compile_info
      };

    { Merlin.
      requires = real_requires
    ; flags
    ; preprocess = Buildable.single_preprocess lib.buildable
    ; libname = Some lib.name
    ; source_dirs = Path.Set.empty
    ; objs_dirs = Path.Set.singleton obj_dir
    }

  (* +-----------------------------------------------------------------+
     | Executables stuff                                               |
     +-----------------------------------------------------------------+ *)

  let executables_rules ~dir ~all_modules
        ?modules_partitioner ~scope (exes : Executables.t) =
    let modules =
      parse_modules ~all_modules ~buildable:exes.buildable
    in
    let already_used =
      match modules_partitioner with
      | None -> String_set.empty
      | Some mp ->
        Modules_partitioner.acknowledge mp
          ~loc:exes.buildable.loc ~modules
    in

    let modules =
      let preprocessor_deps =
        SC.Deps.interpret sctx exes.buildable.preprocessor_deps
          ~scope ~dir
      in
      SC.PP.pp_and_lint_modules sctx ~dir ~dep_kind:Required ~modules ~scope
        ~preprocess:exes.buildable.preprocess
        ~preprocessor_deps
        ~lint:exes.buildable.lint
        ~lib_name:None
    in

    let programs =
      List.map exes.names ~f:(fun (loc, name) ->
        let mod_name = String.capitalize name in
        match String_map.find modules mod_name with
        | Some m ->
          if not (Module.has_impl m) then
            Loc.fail loc "Module %s has no implementation." mod_name
          else
            { Exe.Program.name; main_module_name = mod_name }
        | None -> Loc.fail loc "Module %s doesn't exist." mod_name)
    in

    let linkages =
      [ Exe.Linkage.byte
      ; if exes.modes.native then
          Exe.Linkage.native_or_custom ctx
        else
          Exe.Linkage.custom
      ]
    in

    let flags =
      Ocaml_flags.make exes.buildable sctx ~scope ~dir
    in
    let link_flags =
      SC.expand_and_eval_set sctx exes.link_flags
        ~scope
        ~dir
        ~standard:[]
    in

    let compile_info =
      Lib.DB.resolve_user_written_deps (Scope.libs scope)
        exes.buildable.libraries
        ~pps:(Jbuild.Preprocess_map.pps exes.buildable.preprocess)
    in
    let requires, real_requires =
      SC.Libs.requires sctx ~dir
        ~has_dot_merlin:true
        compile_info
    in

    (* Use "eobjs" rather than "objs" to avoid a potential conflict
       with a library of the same name *)
    let obj_dir =
      Path.relative dir ("." ^ (List.hd programs).name ^ ".eobjs")
    in
    Exe.build_and_link_many sctx
      ~dir
      ~obj_dir
      ~programs
      ~modules
      ~already_used
      ~scope
      ~linkages
      ~requires
      ~flags
      ~link_flags
      ~js_of_ocaml:exes.buildable.js_of_ocaml;

    { Merlin.
      requires    = real_requires
    ; flags       = Ocaml_flags.common flags
    ; preprocess  = Buildable.single_preprocess exes.buildable
    ; libname     = None
    ; source_dirs = Path.Set.empty
    ; objs_dirs   = Path.Set.singleton obj_dir
    }

  (* +-----------------------------------------------------------------+
     | Aliases                                                         |
     +-----------------------------------------------------------------+ *)

  let add_alias ~dir ~name ~stamp ?(locks=[]) build =
    let alias = Build_system.Alias.make name ~dir in
    SC.add_alias_action sctx alias ~locks ~stamp build

  let alias_rules (alias_conf : Alias_conf.t) ~dir ~scope =
    let stamp =
      let module S = Sexp.To_sexp in
      Sexp.List
        [ Sexp.unsafe_atom_of_string "user-alias"
        ; S.list   Jbuild.Dep_conf.sexp_of_t   alias_conf.deps
        ; S.option Action.Unexpanded.sexp_of_t alias_conf.action
        ]
    in
    add_alias
      ~dir
      ~name:alias_conf.name
      ~stamp
      ~locks:(interpret_locks ~dir ~scope alias_conf.locks)
      (SC.Deps.interpret sctx ~scope ~dir alias_conf.deps
       >>>
       match alias_conf.action with
       | None -> Build.progn []
       | Some action ->
         SC.Action.run
           sctx
           action
           ~dir
           ~dep_kind:Required
           ~targets:Alias
           ~scope)

  (* +-----------------------------------------------------------------+
     | Stanza                                                          |
     +-----------------------------------------------------------------+ *)

  let gen_rules { SC.Dir_with_jbuild. src_dir; ctx_dir; stanzas; scope } =
    (* This interprets "rule" and "copy_files" stanzas. *)
    let files = text_files ~dir:ctx_dir in
    let all_modules = modules_by_dir ~dir:ctx_dir in
    let modules_partitioner =
      Modules_partitioner.create ~dir:src_dir ~all_modules
    in
    List.filter_map stanzas ~f:(fun stanza ->
      let dir = ctx_dir in
      match (stanza : Stanza.t) with
      | Library lib ->
        Some (library_rules lib ~dir ~files ~scope ~modules_partitioner)
      | Executables exes ->
        Some (executables_rules exes ~dir ~all_modules ~scope
                ~modules_partitioner)
      | Alias alias ->
        alias_rules alias ~dir ~scope;
        None
      | Copy_files { glob; _ } ->
        let src_dir =
          let loc = String_with_vars.loc glob in
          let src_glob = SC.expand_vars sctx ~dir glob ~scope in
          Path.parent (Path.relative src_dir src_glob ~error_loc:loc)
        in
        Some
          { Merlin.requires = Build.return []
          ; flags           = Build.return []
          ; preprocess      = Jbuild.Preprocess.No_preprocessing
          ; libname         = None
          ; source_dirs     = Path.Set.singleton src_dir
          ; objs_dirs       = Path.Set.empty
          }
      | _ -> None)
    |> Merlin.merge_all
    |> Option.map ~f:(fun (m : Merlin.t) ->
      { m with source_dirs =
                 Path.Set.add m.source_dirs (Path.relative src_dir ".")
      })
    |> Option.iter ~f:(Merlin.add_rules sctx ~dir:ctx_dir ~scope);
    Utop.setup sctx ~dir:ctx_dir ~libs:(
      List.filter_map stanzas ~f:(function
        | Stanza.Library lib -> Some lib
        | _ -> None)
    ) ~scope;
    Modules_partitioner.emit_warnings modules_partitioner

  (* +-----------------------------------------------------------------+
     | META                                                            |
     +-----------------------------------------------------------------+ *)

  let lib_dune_file ~dir ~name =
    Path.relative dir (name ^ ".dune")

  let gen_lib_dune_file lib =
    SC.add_rule sctx
      (Build.arr (fun () ->
         Format.asprintf "%a@." Sexp.pp
           (Lib.Sub_system.dump_config lib |> Installed_dune_file.gen))
       >>> Build.write_file_dyn
             (lib_dune_file ~dir:(Lib.src_dir lib) ~name:(Lib.name lib)))

  let init_meta () =
    let public_libs = Lib.DB.all (SC.public_libs sctx) in
    List.iter public_libs ~f:gen_lib_dune_file;
    List.map public_libs ~f:(fun lib ->
      (Findlib.root_package_name (Lib.name lib), lib))
    |> String_map.of_list_multi
    |> String_map.merge (SC.packages sctx) ~f:(fun _name pkg libs ->
      let pkg  = Option.value_exn pkg          in
      let libs = Option.value libs ~default:[] in
      Some (pkg, libs))
    |> String_map.iter ~f:(fun ((pkg : Package.t), libs) ->
      let path = Path.append ctx.build_dir pkg.path in
      SC.on_load_dir sctx ~dir:path ~f:(fun () ->
        let meta_fn = "META." ^ pkg.name in

        let meta_template = Path.relative path (meta_fn ^ ".template"     ) in
        let meta          = Path.relative path  meta_fn                     in

        let version =
          let get =
            match pkg.version_from_opam_file with
            | Some s -> Build.return (Some s)
            | None ->
              let rec loop = function
                | [] -> Build.return None
                | candidate :: rest ->
                  let p = Path.relative path candidate in
                  Build.if_file_exists p
                    ~then_:(Build.lines_of p
                            >>^ function
                            | ver :: _ -> Some ver
                            | _ -> Some "")
                    ~else_:(loop rest)
              in
              loop
                [ pkg.name ^ ".version"
                ; "version"
                ; "VERSION"
                ]
          in
          Super_context.Pkg_version.set sctx pkg get
        in

        let template =
          Build.if_file_exists meta_template
            ~then_:(Build.lines_of meta_template)
            ~else_:(Build.return ["# JBUILDER_GEN"])
        in
        let meta_contents =
          version >>^ fun version ->
          Gen_meta.gen
            ~package:pkg.name
            ~version
            libs
        in
        SC.add_rule sctx
          (Build.fanout meta_contents template
           >>^ (fun ((meta : Meta.t), template) ->
             let buf = Buffer.create 1024 in
             let ppf = Format.formatter_of_buffer buf in
             Format.pp_open_vbox ppf 0;
             List.iter template ~f:(fun s ->
               if String.is_prefix s ~prefix:"#" then
                 match
                   String.extract_blank_separated_words
                     (String.sub s ~pos:1 ~len:(String.length s - 1))
                 with
                 | ["JBUILDER_GEN"] -> Format.fprintf ppf "%a@," Meta.pp meta.entries
                 | _ -> Format.fprintf ppf "%s@," s
               else
                 Format.fprintf ppf "%s@," s);
             Format.pp_close_box ppf ();
             Format.pp_print_flush ppf ();
             Buffer.contents buf)
           >>>
           Build.write_file_dyn meta)))

  (* +-----------------------------------------------------------------+
     | Installation                                                    |
     +-----------------------------------------------------------------+ *)

  let lib_install_files ~dir ~sub_dir ~scope ~name (lib : Library.t) =
    let obj_dir = Utils.library_object_directory ~dir lib.name in
    let make_entry section ?dst fn =
      Install.Entry.make section fn
        ~dst:(
          let dst =
            match dst with
            | Some s -> s
            | None   -> Path.basename fn
          in
          match sub_dir with
          | None -> dst
          | Some dir -> sprintf "%s/%s" dir dst)
    in
    let { Mode.Dict. byte; native } = lib.modes in
    let if_ cond l = if cond then l else [] in
    let native = native && Option.is_some ctx.ocamlopt in
    let files =
      let modules = module_names_of_lib lib ~dir in
      List.concat
        [ List.concat_map modules ~f:(fun m ->
            List.concat
              [ [ Module.cm_file_unsafe m ~obj_dir Cmi ]
              ; if_ (native && Module.has_impl m)
                  [ Module.cm_file_unsafe m ~obj_dir Cmx ]
              ; List.filter_map Ml_kind.all ~f:(Module.cmt_file m ~obj_dir)
              ; List.filter_map [m.intf;m.impl] ~f:(function
                  | None -> None
                  | Some f -> Some (Path.relative dir f.name))
              ])
        ; if_ byte [ lib_archive ~dir lib ~ext:".cma" ]
        ; if_ (Library.has_stubs lib) [ stubs_archive ~dir lib ]
        ; if_ native
            (let files =
               [ lib_archive ~dir lib ~ext:".cmxa"
               ; lib_archive ~dir lib ~ext:ctx.ext_lib
               ]
             in
             if ctx.natdynlink_supported && lib.dynlink then
               files @ [ lib_archive ~dir lib ~ext:".cmxs" ]
             else
               files)
        ; List.map lib.buildable.js_of_ocaml.javascript_files ~f:(Path.relative dir)
        ; List.map lib.install_c_headers ~f:(fun fn ->
            Path.relative dir (fn ^ ".h"))
        ]
    in
    let dlls  = if_ (byte && Library.has_stubs lib && lib.dynlink) [dll ~dir lib] in
    let execs =
      match lib.kind with
      | Normal | Ppx_deriver -> []
      | Ppx_rewriter ->
        let pps = [(lib.buildable.loc, Pp.of_string lib.name)] in
        let pps =
          (* This is a temporary hack until we get a standard driver *)
          let deps =
            List.concat_map lib.buildable.libraries ~f:Lib_dep.to_lib_names
          in
          if List.exists deps ~f:(function
            | "ppx_driver" | "ppx_type_conv" -> true
            | _ -> false) then
            pps @ [match Scope.name scope with
              | Some "ppxlib" ->
                Loc.none, Pp.of_string "ppxlib.runner"
              | _ ->
                Loc.none, Pp.of_string "ppx_driver.runner"]
          else
            pps
        in
        let ppx_exe = SC.PP.get_ppx_driver sctx ~scope pps in
        [ppx_exe]
    in
    List.concat
      [ List.map files ~f:(make_entry Lib    )
      ; List.map execs ~f:(make_entry Libexec)
      ; List.map dlls  ~f:(Install.Entry.make Stublibs)
      ; [make_entry Lib (lib_dune_file ~dir ~name)]
      ]

  let is_odig_doc_file fn =
    List.exists [ "README"; "LICENSE"; "CHANGE"; "HISTORY"]
      ~f:(fun prefix -> String.is_prefix fn ~prefix)

  let local_install_rules (entries : Install.Entry.t list) ~package =
    let install_dir = Config.local_install_dir ~context:ctx.name in
    List.map entries ~f:(fun entry ->
      let dst =
        Path.append install_dir (Install.Entry.relative_installed_path entry ~package)
      in
      SC.add_rule sctx (Build.symlink ~src:entry.src ~dst);
      Install.Entry.set_src entry dst)

  let promote_install_file =
    not ctx.implicit &&
    match ctx.kind with
    | Default -> true
    | Opam _  -> false

  let install_file package_path package entries =
    let entries =
      let files = SC.source_files sctx ~src_path:Path.root in
      String_set.fold files ~init:entries ~f:(fun fn acc ->
        if is_odig_doc_file fn then
          Install.Entry.make Doc (Path.relative ctx.build_dir fn) :: acc
        else
          acc)
    in
    let entries =
      let opam = Path.relative package_path (package ^ ".opam") in
      Install.Entry.make Lib opam ~dst:"opam" :: entries
    in
    let entries =
      let meta_fn = "META." ^ package in
      let meta = Path.append ctx.build_dir (Path.relative package_path meta_fn) in
      Install.Entry.make Lib meta ~dst:"META" :: entries
    in
    let fn =
      Path.relative (Path.append ctx.build_dir package_path)
        (Utils.install_file ~package ~findlib_toolchain:ctx.findlib_toolchain)
    in
    let entries = local_install_rules entries ~package in
    SC.add_rule sctx
      ~mode:(if promote_install_file then
               Promote_but_delete_on_clean
             else
               (* We must ignore the source file since it might be
                  copied to the source tree by another context. *)
               Ignore_source_files)
      (Build.path_set (Install.files entries)
       >>^ (fun () ->
         let entries =
           match ctx.findlib_toolchain with
           | None -> entries
           | Some toolchain ->
             let prefix = Path.of_string (toolchain ^ "-sysroot") in
             List.map entries
               ~f:(Install.Entry.add_install_prefix ~prefix ~package)
         in
         Install.gen_install_file entries)
       >>>
       Build.write_file_dyn fn)

  let init_install () =
    let entries_per_package =
      List.concat_map (SC.stanzas_to_consider_for_install sctx)
        ~f:(fun (dir, scope, stanza) ->
          match stanza with
          | Library ({ public = Some { package; sub_dir; name; _ }; _ } as lib) ->
            List.map (lib_install_files ~dir ~sub_dir ~scope ~name lib)
              ~f:(fun x -> package.name, x)
          | Install { section; files; package}->
            List.map files ~f:(fun { Install_conf. src; dst } ->
              (package.name,
               Install.Entry.make section (Path.relative dir src) ?dst))
          | _ -> [])
      |> String_map.of_list_multi
    in
    String_map.iter (SC.packages sctx) ~f:(fun (pkg : Package.t) ->
      let stanzas =
        Option.value (String_map.find entries_per_package pkg.name) ~default:[]
      in
      install_file pkg.path pkg.name stanzas)

  let init_install_files () =
    if not ctx.implicit then
      String_map.iteri (SC.packages sctx)
        ~f:(fun pkg { Package.path = src_path; _ } ->
          let install_fn =
            Utils.install_file ~package:pkg
              ~findlib_toolchain:ctx.findlib_toolchain
          in

          let path = Path.append ctx.build_dir src_path in
          let install_alias = Alias.install ~dir:path in
          let install_file = Path.relative path install_fn in
          SC.add_alias_deps sctx install_alias [install_file])

  let init () =
    init_meta ();
    init_install ();
    init_install_files ()

  let gen_rules ~dir components : Build_system.extra_sub_directories_to_keep =
    (match components with
     | ".js"  :: rest -> Js_of_ocaml_rules.setup_separate_compilation_rules
                           sctx rest
     | "_doc" :: rest -> Odoc.gen_rules sctx rest ~dir
     | ".ppx"  :: rest -> SC.PP.gen_rules sctx rest
     | _ ->
       match Path.Map.find stanzas_per_dir dir with
       | Some x -> gen_rules x
       | None ->
         if components <> [] &&
            Option.is_none
              (File_tree.find_dir (SC.file_tree sctx)
                 (Path.drop_build_context_exn dir)) then
           SC.load_dir sctx ~dir:(Path.parent dir));
    match components with
    | [] -> These (String_set.of_list [".js"; "_doc"; ".ppx"])
    | [(".js"|"_doc"|".ppx")] -> All
    | _  -> These String_set.empty
end

module type Gen = sig
  val gen_rules
    :  dir:Path.t
    -> string list
    -> Build_system.extra_sub_directories_to_keep
  val init : unit -> unit
end

let gen' sctx =
  let module M = Gen(struct let sctx = sctx end) in
  (module M : Gen)

let gen ~contexts ~build_system
      ?(filter_out_optional_stanzas_with_missing_deps=true)
      ?only_packages conf =
  let { Jbuild_load. file_tree; jbuilds; packages; scopes } = conf in
  let packages =
    match only_packages with
    | None -> packages
    | Some pkgs ->
      String_map.filter packages ~f:(fun { Package.name; _ } ->
        String_set.mem pkgs name)
  in
  let sctxs = Hashtbl.create 4 in
  List.iter contexts ~f:(fun c ->
    Hashtbl.add sctxs c.Context.name (Fiber.Ivar.create ()));
  let make_sctx (context : Context.t) =
    let host () =
      match context.for_host with
      | None -> None
      | Some h ->
        Some (Fiber.Ivar.read (Option.value_exn (Hashtbl.find sctxs h.name)))
    in
    let stanzas () =
      let stanzas = Jbuild_load.Jbuilds.eval ~context jbuilds in
      match only_packages with
      | None -> stanzas
      | Some pkgs ->
        List.map stanzas ~f:(fun (dir, pkgs_ctx, stanzas) ->
          (dir,
           pkgs_ctx,
           List.filter stanzas ~f:(fun stanza ->
             match (stanza : Stanza.t) with
             | Library { public = Some { package; _ }; _ }
             | Alias { package = Some package ;  _ }
             | Install { package; _ } ->
               String_set.mem pkgs package.name
             | _ -> true)))
    in
    let (host, stanzas) = Fiber.fork_and_join host stanzas in
    let sctx =
      Super_context.create
        ?host
        ~build_system
        ~context
        ~scopes
        ~file_tree
        ~packages
        ~filter_out_optional_stanzas_with_missing_deps
        ~stanzas
    in
    let g = gen' sctx in
    Fiber.Ivar.fill (Option.value_exn (Hashtbl.find sctxs context.name)) sctx;
    (context.name, (g, stanzas))
  in
  let l = Fiber.parallel_map contexts ~f:make_sctx in
  let map = String_map.of_list_exn l in
  Build_system.set_rule_generators build_system
    (String_map.map map ~f:(fun ((module M : Gen), _) -> M.gen_rules));
  String_map.iter map ~f:(fun ((module M : Gen), _) -> M.init ());
  String_map.map map ~f:snd
