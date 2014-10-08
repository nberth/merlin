open Std
open Merlin_lib

let sources_path = ref (Misc.Path_list.of_list [])
let cmt_path = ref (Misc.Path_list.of_list [])

let cwd = ref ""

let section = Logger.section "locate"

module Utils = struct
  (* FIXME: turn this into proper debug logging *)
  let debug_log x =
    Printf.ksprintf (Logger.info section)  x

  let is_ghost { Location. loc_ghost } = loc_ghost = true

  let path_to_list p =
    let rec aux acc = function
      | Path.Pident id -> id.Ident.name :: acc
      | Path.Pdot (p, str, _) -> aux (str :: acc) p
      | _ -> assert false
    in
    aux [] p

  let file_path_to_mod_name f =
    let pref = Misc.chop_extensions f in
    String.capitalize (Filename.basename pref)

  type filetype =
    | ML   of string
    | MLI  of string
    | CMT  of string
    | CMTI of string

  exception File_not_found of filetype

  let filename_of_filetype = function ML name | MLI name | CMT name | CMTI name -> name
  let ext_of_filetype = function
    | ML _  -> ".ml"  | MLI _  -> ".mli"
    | CMT _ -> ".cmt" | CMTI _ -> ".cmti"

  let find_file file =
    let fname =
      (* FIXME: the [Misc.chop_extension_if_any] should have no effect here,
         make sure of that and then remove it. *)
      Misc.chop_extension_if_any (filename_of_filetype file)
      ^ (ext_of_filetype file)
    in
    (* FIXME: that sucks, if [cwd] = ".../_build/..." the ".ml" will exist, but
       will most likely not be the one you want to edit.
       However, just using [find_in_path_uncap] won't work either when you have
       several ml files with the same name (which can only happen in presence of packed
       modules).
       Example: scheduler.ml and raw_scheduler.ml are present in both async_core
       and async_unix. (ofc. "std.ml" is a more common example.)

       N.B. [cwd] is set only when we have encountered a packed module and we
       use it only when set, we don't want to look in the actual cwd of merlin
       when looking for files. *)
    try
      if !cwd = "" then raise Not_found ;
      Misc.(find_in_path_uncap (Path_list.of_string_list_ref (ref [ !cwd ])))
        fname
    with Not_found ->
    try
      let path =
        match file with
        | ML  _ | MLI _  -> !sources_path
        | CMT _ | CMTI _ -> !cmt_path
      in
      Misc.find_in_path_uncap path fname
    with Not_found ->
      raise (File_not_found file)

  let find_file ?(with_fallback=false) file =
    try find_file file
    with File_not_found _ as exn ->
      if not with_fallback then raise exn else
      let fallback =
        match file with
        | ML f -> MLI f
        | MLI f -> ML f
        | CMT f -> CMTI f
        | CMTI f -> CMT f
      in
      debug_log "no %s, looking for %s of %s" (ext_of_filetype file)
        (ext_of_filetype fallback) (filename_of_filetype file);
      try find_file fallback
      with File_not_found _ -> raise exn

  let keep_suffix =
    let open Longident in
    let rec aux = function
      | Lident str ->
        if String.lowercase str <> str then
          Some (Lident str, false)
        else
          None
      | Ldot (t, str) ->
        if String.lowercase str <> str then
          match aux t with
          | None -> Some (Lident str, true)
          | Some (t, is_label) -> Some (Ldot (t, str), is_label)
        else
          None
      | t ->
        Some (t, false) (* don't know what to do here, probably best if I do nothing. *)
    in
    function
    | Lident s -> Lident s, false
    | Ldot (t, s) ->
      begin match aux t with
      | None -> Lident s, true
      | Some (t, is_label) -> Ldot (t, s), is_label
      end
    | otherwise -> otherwise, false
end

include Utils

type result = [
  | `Found of string option * Lexing.position
  | `Not_in_env of string
  | `File_not_found of string
  | `Not_found
]

(** Reverse the list of items − we want to start from the bottom of
    the file − and remove top level indirections. *)
let get_top_items browsable =
  List.concat_map (fun bt ->
    let open BrowseT in
    match bt.t_node with
    | Signature _
    | Structure _ -> List.rev (Lazy.force bt.t_children)
    | Signature_item _
    | Structure_item _-> [ bt ]
    | _ -> []
  ) browsable

let rec check_item ~source modules =
  let get_loc ~name item rest =
    let ident_locs, is_included =
      let open Merlin_types_custom in
      match item.BrowseT.t_node with
      | BrowseT.Structure_item item ->
        str_ident_locs item, get_mod_expr_if_included item
      | BrowseT.Signature_item item ->
        sig_ident_locs item, get_mod_type_if_included item
      | _ -> assert false
    in
    try
      let res = List.assoc name ident_locs in
      if source then `ML res else `MLI res
    with Not_found ->
      match is_included ~name with
      | `Not_included -> check_item ~source modules rest
      | `Mod_expr incl_mod ->
        debug_log "one more include to follow..." ;
        resolve_mod_alias ~source ~fallback:item.BrowseT.t_loc (BrowseT.Module_expr incl_mod)
          [ name ] rest
      | `Mod_type incl_mod ->
        debug_log "one more include to follow..." ;
        resolve_mod_alias ~source ~fallback:item.BrowseT.t_loc (BrowseT.Module_type incl_mod)
          [ name ] rest
  in
  let get_on_track ~name item =
    match
      let open Merlin_types_custom in
      match item.BrowseT.t_node with
      | BrowseT.Structure_item item ->
        get_mod_expr_if_included ~name item,
        begin try
          let mbs = expose_module_binding item in
          let mb = List.find ~f:(fun mb -> Ident.name mb.Typedtree.mb_id = name) mbs in
          debug_log "(get_on_track) %s is bound" name ;
          `Direct (BrowseT.Module_expr mb.Typedtree.mb_expr)
        with Not_found -> `Not_found end
      | BrowseT.Signature_item item ->
        get_mod_type_if_included ~name item,
        begin try
          let mds = expose_module_declaration item in
          let md = List.find ~f:(fun md -> Ident.name md.Typedtree.md_id = name) mds in
          debug_log "(get_on_track) %s is bound" name ;
          `Direct (BrowseT.Module_type md.Typedtree.md_type)
        with Not_found -> `Not_found end
      | _ -> assert false
    with
    | `Mod_expr incl_mod, `Not_found ->
      debug_log "(get_on_track) %s is included..." name ;
      `Included (BrowseT.Module_expr incl_mod)
    | `Mod_type incl_mod, `Not_found ->
      debug_log "(get_on_track) %s is included..." name ;
      `Included (BrowseT.Module_type incl_mod)
    | `Not_included, otherwise -> otherwise
    | _ -> assert false
  in
  function
  | [] ->
    debug_log "%s not in current file..." (String.concat ~sep:"." modules) ;
    from_path ~source modules
  | item :: rest ->
    match modules with
    | [] -> assert false
    | [ str_ident ] -> get_loc ~name:str_ident item rest
    | mod_name :: path ->
      begin match
        match get_on_track ~name:mod_name item with
        | `Not_found -> None
        | `Direct me -> Some (path, me)
        | `Included me -> Some (modules, me)
      with
      | None -> check_item ~source modules rest
      | Some (path, me) ->
        resolve_mod_alias ~source ~fallback:item.BrowseT.t_loc me path rest
      end

and browse_cmts ~root modules =
  let open Cmt_format in
  let cmt_infos = read_cmt root in
  (* TODO: factorize *)
  match cmt_infos.cmt_annots with
  | Interface intf ->
    begin match modules with
    | [] ->
      let pos = Lexing.make_pos ~pos_fname:root (1, 0) in
      `MLI { Location. loc_start = pos ; loc_end = pos ; loc_ghost = false }
    | _ ->
      let browses   = Browse.of_typer_contents [ `Sg intf ] in
      let browsable = get_top_items browses in
      check_item ~source:false modules browsable
    end
  | Implementation impl ->
    begin match modules with
    | [] -> (* we were looking for a module, we found the right file, we're happy *)
      let pos = Lexing.make_pos ~pos_fname:root (1, 0) in
      `ML { Location. loc_start = pos ; loc_end = pos ; loc_ghost = false }
    | _ ->
      let browses   = Browse.of_typer_contents [ `Str impl ] in
      let browsable = get_top_items browses in
      check_item ~source:true modules browsable 
    end
  | Packed (_, files) ->
    begin match modules with
    | [] -> `Not_found
    | mod_name :: modules ->
      let file = 
        List.(find (map files ~f:file_path_to_mod_name)) ~f:((=) mod_name)
      in
      cwd := Filename.dirname root ;
      debug_log "Saw packed module => setting cwd to '%s'" !cwd ;
      let cmt_file = find_file ~with_fallback:true (CMT file) in
      browse_cmts ~root:cmt_file modules
    end
  | _ -> `Not_found (* TODO? *)

and from_path ~source ?(fallback=`Not_found) =
  let recover = function
    | `Not_found -> fallback
    | otherwise -> otherwise
  in
  function
  | [] -> invalid_arg "empty path"
  | [ fname ] ->
    let pos = Lexing.make_pos ~pos_fname:fname (1, 0) in
    let loc = { Location. loc_start=pos ; loc_end=pos ; loc_ghost=true } in
    if source then `ML loc else `MLI loc
  | fname :: modules ->
    try
      let cmt_file = find_file ~with_fallback:true (CMT fname) in
      recover (browse_cmts ~root:cmt_file modules)
    with
    | Not_found -> recover `Not_found
    | File_not_found (CMT fname) as exn ->
      debug_log "failed to locate the cmt[i] of '%s'" fname ;
      begin match fallback with
      | `Not_found  -> raise exn
      | value -> value
      end
    | File_not_found _ -> assert false

and resolve_mod_alias ~source ~fallback node path rest =
  let do_fallback = function
    | `Not_found -> if source then `ML fallback else `MLI fallback
    | otherwise  -> otherwise
  in
  let direct, loc =
    match node with
    | BrowseT.Module_expr me  ->
      Merlin_types_custom.remove_indir_me me, me.Typedtree.mod_loc
    | BrowseT.Module_type mty ->
      Merlin_types_custom.remove_indir_mty mty, mty.Typedtree.mty_loc
    | _ -> assert false (* absurd *)
  in
  match direct with
  | `Alias path' ->
    let full_path = (path_to_list path') @ path in
    do_fallback (check_item ~source full_path rest)
  | `Sg _ | `Str _ as x ->
    let lst = get_top_items (Browse.of_typer_contents [ x ]) @ rest in
    do_fallback (check_item ~source path lst)
  | `Functor msg ->
    debug_log "stopping on functor%s" msg ;
    if source then `ML loc else `MLI loc
  | `Mod_type mod_type ->
    resolve_mod_alias ~source ~fallback (BrowseT.Module_type mod_type) path rest
  | `Mod_expr mod_expr ->
    resolve_mod_alias ~source ~fallback (BrowseT.Module_expr mod_expr) path rest
  | `Unpack -> (* FIXME: should we do something or stop here? *)
    debug_log "found Tmod_unpack, expect random results." ;
    do_fallback (check_item ~source path rest)

let path_and_loc_from_label desc env =
  let open Types in
  match desc.lbl_res.desc with
  | Tconstr (path, _, _) ->
    let typ_decl = Env.find_type path env in
    path, typ_decl.Types.type_loc
  | _ -> assert false

exception Not_in_env

let from_string ~project ~env ~local_defs is_implementation path =
  cwd := "" (* Reset the cwd before doing anything *) ;
  sources_path := Project.source_path project ;
  cmt_path := Project.cmt_path project ;
  debug_log "looking for the source of '%s'" path ;
  let ident, is_label = keep_suffix (Longident.parse path) in
  let str_ident = String.concat ~sep:"." (Longident.flatten ident) in
  try
    let path, loc =
      (* [1] If we know it is a record field, we only look for that. *)
      if is_label then
        let label_desc = Merlin_types_custom.lookup_label ident env in
        path_and_loc_from_label label_desc env
      else (
        try
          let path, val_desc = Env.lookup_value ident env in
          path, val_desc.Types.val_loc
        with Not_found ->
        try
          let path, typ_decl = Env.lookup_type ident env in
          path, typ_decl.Types.type_loc
        with Not_found ->
        try
          let cstr_desc = Merlin_types_custom.lookup_constructor ident env in
          Merlin_types_custom.path_and_loc_of_cstr cstr_desc env
        with Not_found ->
        try
          let path, _ = Merlin_types_custom.lookup_module ident env in
          path, Location.symbol_gloc ()
        with Not_found ->
        try
          (* However, [1] is not the only time where we can have a record field,
              we could also have found the ident in a pattern like
                  | { x ; y } -> e
              in which case the check before [1] won't know that we have a
              label, but it's worth checking at this point. *)
          let label_desc = Merlin_types_custom.lookup_label ident env in
          path_and_loc_from_label label_desc env
        with Not_found ->
          debug_log "   ... not in the environment" ;
          raise Not_in_env
      )
    in
    if not (is_ghost loc) then
      `Found (None, loc.Location.loc_start)
    else
      match
        let modules = path_to_list path in
        let local_defs = Browse.of_typer_contents local_defs in
        (* FIXME: that's true only if we are in an ML file, not in an MLI *)
        check_item ~source:is_implementation modules (get_top_items local_defs)
      with
      | `Not_found -> `Not_found
      | `ML loc ->
        let fname = loc.Location.loc_start.Lexing.pos_fname in
        let with_fallback = loc.Location.loc_ghost in
        let full_path = find_file ~with_fallback (ML (file_path_to_mod_name fname)) in
        `Found (Some full_path, loc.Location.loc_start)
      | `MLI loc ->
        let fname = loc.Location.loc_start.Lexing.pos_fname in
        let with_fallback = loc.Location.loc_ghost in
        let full_path = find_file ~with_fallback (MLI (file_path_to_mod_name fname)) in
        `Found (Some full_path, loc.Location.loc_start)
  with
  | Not_found -> `Not_found
  | File_not_found path ->
    let msg =
      match path with
      | ML file ->
        Printf.sprintf "'%s' seems to originate from '%s' whose ML file could not be found"
          str_ident file
      | MLI file ->
        Printf.sprintf "'%s' seems to originate from '%s' whose MLI file could not be found"
          str_ident file
      | CMT file ->
        Printf.sprintf "Needed cmt file of module '%s' to locate '%s' but it is not present"
          file str_ident
      | CMTI file ->
        Printf.sprintf "Needed cmti file of module '%s' to locate '%s' but it is not present"
          file str_ident
    in
    `File_not_found msg
  | Not_in_env -> `Not_in_env str_ident
