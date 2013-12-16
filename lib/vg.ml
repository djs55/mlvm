(*
 * Copyright (C) 2009-2013 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Absty
open Redo
open Logging

type status =
    | Read
    | Write
    | Resizeable
    | Clustered

and vg = {
  name : string;
  id : Uuid.t;
  seqno : int;
  status : status list;
  extent_size : int64;
  max_lv : int;
  max_pv : int;
  pvs : Pv.t list; (* Device to pv map *)
  lvs : Lv.logical_volume list;
  free_space : Allocator.t;
  (* XXX: hook in the redo log *)
  ops : sequenced_op list;
} with rpc
  
let status_to_string s =
  match s with
    | Resizeable -> "RESIZEABLE"
    | Write -> "WRITE"
    | Read -> "READ"
    | Clustered -> "CLUSTERED"

open Result

let status_of_string s =
  match s with 
    | "RESIZEABLE" -> return Resizeable
    | "WRITE" -> return Write
    | "READ" -> return Read
    | "CLUSTERED" -> return Clustered
    | x -> fail (Printf.sprintf "Bad VG status string: %s" x)

let write_to_buffer b vg =
  let bprintf = Printf.bprintf in
  bprintf b "%s {\nid = \"%s\"\nseqno = %d\n"
    vg.name (Uuid.to_string vg.id) vg.seqno;
  bprintf b "status = [%s]\nextent_size = %Ld\nmax_lv = %d\nmax_pv = %d\n\n"
    (String.concat ", " (List.map (o quote status_to_string) vg.status))
    vg.extent_size vg.max_lv vg.max_pv;

  bprintf b "physical_volumes {\n";
  List.iter (Pv.to_buffer b) vg.pvs;
  bprintf b "}\n\n";

  bprintf b "logical_volumes {\n";
  List.iter (Lv.write_to_buffer b) vg.lvs;
  bprintf b "}\n}\n";

  bprintf b "# Generated by MLVM version 0.1: \n\n";
  bprintf b "contents = \"Text Format Volume Group\"\n";
  bprintf b "version = 1\n\n";
  bprintf b "description = \"\"\n\n";
  bprintf b "creation_host = \"%s\"\n" "<need uname!>";
  bprintf b "creation_time = %Ld\n\n" (Int64.of_float (Unix.time ()))
    

let to_cstruct vg = 
  let b = Buffer.create 65536 in 
  write_to_buffer b vg;
  let s = Buffer.contents b in
  let c = Cstruct.create (String.length s) in
  Cstruct.blit_from_string s 0 c 0 (String.length s);
  c

(*************************************************************)
(* METADATA CHANGING OPERATIONS                              *)
(*************************************************************)

let do_op vg op : (vg, string) Result.result =
  ( if vg.seqno <> op.so_seqno
    then fail (Printf.sprintf "VG: cannot perform operation out-of-order: expected %d, actual %d" vg.seqno op.so_seqno)
    else return () ) >>= fun () ->
  let rec createsegs acc ss s_start_extent = match ss with
  | a::ss ->
    let l_pv_start_extent = Allocator.get_start a in
    let s_extent_count = Allocator.get_size a in
    let l_pv_name = Allocator.get_name a in
    let s_cls = Lv.Linear { Lv.l_pv_name; l_pv_start_extent; } in
    createsegs ({ Lv.s_start_extent; s_cls; s_extent_count } :: acc) ss  (Int64.add s_start_extent s_extent_count)
  | [] -> List.rev acc in	
  let change_lv lv_name fn =
    let lv,others = List.partition (fun lv -> lv.Lv.name=lv_name) vg.lvs in
    match lv with
    | [lv] -> fn lv others
    | _ -> fail (Printf.sprintf "VG: unknown LV %s" lv_name) in
  let vg = {vg with seqno = vg.seqno + 1; ops=op::vg.ops} in
  match op.so_op with
  | LvCreate (name,l) ->
    let new_free_space = Allocator.alloc_specified_areas vg.free_space l.lvc_segments in
    let segments = Lv.sort_segments (createsegs [] l.lvc_segments 0L) in
    let lv = { Lv.name; id = l.lvc_id; tags = []; status = [Lv.Read; Lv.Visible]; segments } in
    return {vg with lvs = lv::vg.lvs; free_space = new_free_space}
  | LvExpand (name,l) ->
    change_lv name (fun lv others ->
      let old_size = Lv.size_in_extents lv in
      let free_space = Allocator.alloc_specified_areas vg.free_space l.lvex_segments in
      let segments = createsegs [] l.lvex_segments old_size in
      let segments = Lv.sort_segments (segments @ lv.Lv.segments) in
      let lv = {lv with Lv.segments} in
      return {vg with lvs = lv::others; free_space=free_space} )
  | LvReduce (name,l) ->
    change_lv name (fun lv others ->
      let allocation = Lv.allocation_of_lv lv in
      Lv.reduce_size_to lv l.lvrd_new_extent_count >>= fun lv ->
      let new_allocation = Lv.allocation_of_lv lv in
      let free_space = Allocator.alloc_specified_areas (Allocator.free vg.free_space allocation) new_allocation in
      return {vg with lvs = lv::others; free_space})
  | LvRemove name ->
    change_lv name (fun lv others ->
      let allocation = Lv.allocation_of_lv lv in
      return {vg with lvs = others; free_space = Allocator.free vg.free_space allocation })
  | LvRename (name,l) ->
    change_lv name (fun lv others ->
      return {vg with lvs = {lv with Lv.name=l.lvmv_new_name}::others })
  | LvAddTag (name, tag) ->
    change_lv name (fun lv others ->
      let tags = lv.Lv.tags in
      let lv' = {lv with Lv.tags = if List.mem tag tags then tags else tag::tags} in
      return {vg with lvs = lv'::others})
  | LvRemoveTag (name, tag) ->
    change_lv name (fun lv others ->
      let tags = lv.Lv.tags in
      let lv' = {lv with Lv.tags = List.filter (fun t -> t <> tag) tags} in
      return {vg with lvs = lv'::others})

let create_lv vg name size =
  let id = Uuid.create () in
  let new_segments,new_free_space = Allocator.alloc vg.free_space size in
  do_op vg {so_seqno=vg.seqno; so_op=LvCreate (name,{lvc_id=id; lvc_segments=new_segments})}

let rename_lv vg old_name new_name =
  do_op vg {so_seqno=vg.seqno; so_op=LvRename (old_name,{lvmv_new_name=new_name})}

let resize_lv vg name new_size =
  let lv,others = List.partition (fun lv -> lv.Lv.name=name) vg.lvs in
  ( match lv with 
    | [lv] ->
	let current_size = Lv.size_in_extents lv in
	if new_size > current_size then
	  let new_segs,_ = Allocator.alloc vg.free_space (Int64.sub new_size current_size) in
	  return (LvExpand (name,{lvex_segments=new_segs}))
	else
	  return (LvReduce (name,{lvrd_new_extent_count=new_size}))
    | _ -> fail (Printf.sprintf "Can't find LV %s" name) ) >>= fun op ->
  do_op vg {so_seqno=vg.seqno; so_op=op}

let remove_lv vg name =
  do_op vg {so_seqno=vg.seqno; so_op=LvRemove name}

let add_tag_lv vg name tag =
  do_op vg {so_seqno = vg.seqno; so_op = LvAddTag (name, tag)}

let remove_tag_lv vg name tag =
  do_op vg {so_seqno = vg.seqno; so_op = LvRemoveTag (name, tag)}

(******************************************************************************)
(*
let human_readable vg =
  let pv_strings = List.map Pv.human_readable vg.pvs in
    String.concat "\n" pv_strings


let find_lv vg lv_name =
  List.find (fun lv -> lv.Lv.name = lv_name) vg.lvs

let with_open_redo vg f =
  debug "The redo log is missing"

let read_redo vg =
	with_open_redo vg (fun (fd,pos) ->
				   Redo.read fd pos (Constants.extent_size))

let write_redo vg =
  with_open_redo vg (fun (fd,pos) ->
    Redo.write fd pos (Constants.extent_size) vg.ops;
    {vg with ops=[]})
    
let reset_redo vg =
  with_open_redo vg (fun (fd,pos) ->
    Redo.reset fd pos)

let apply_redo vg  =
  let ops = List.rev (read_redo vg) in
  let rec apply vg ops =
    match ops with
      | op::ops ->
	  if op.so_seqno=vg.seqno 
	  then begin
	    debug "Applying operation op=%s" (Redo.redo_to_human_readable op);
            do_op vg op >>= fun vg ->
	    apply vg ops
	  end else begin
	    debug "Ignoring operation op=%s" (Redo.redo_to_human_readable op);
	    apply vg ops
	  end
      | _ -> return vg
  in apply vg ops
*)

let write_full vg =
  let pvs = vg.pvs in
  let md = to_cstruct vg in
  let open IO in
  let rec write_pv pv acc = function
    | [] -> return (List.rev acc)
    | m :: ms ->
      Metadata.write pv.Pv.real_device m md >>= fun h ->
      write_pv pv (h :: acc) ms in
  let rec write_vg acc = function
    | [] -> return (List.rev acc)
    | pv :: pvs ->
      Label.write pv.Pv.label >>= fun () ->
      write_pv pv [] pv.Pv.mda_headers >>= fun headers ->
      write_vg ({ pv with Pv.mda_headers = headers } :: acc) pvs in
  write_vg [] vg.pvs >>= fun pvs ->
  let vg = { vg with pvs } in
  (* (match vg.redo_lv with Some _ -> reset_redo vg | None -> ()); *)
  return vg

(*
let init_redo_log vg =
  let open IO.FromResult in
  match vg.redo_lv with 
    | Some _ -> return vg 
    | None ->
      create_lv vg Constants.redo_log_lv_name 1L >>= fun lv ->
      let open IO in
      write_full lv >>= fun vg ->
      return { vg with redo_lv = Some Constants.redo_log_lv_name }
*)
let write vg force_full =
  write_full vg

let of_metadata config =
  let open IO.FromResult in
  ( match config with
    | AStruct c -> `Ok c
    | _ -> `Error "VG metadata doesn't begin with a structure element" ) >>= fun config ->
  let vg = filter_structs config in
  ( match vg with
    | [ name, _ ] -> `Ok name
    | [] -> `Error "VG metadata contains no defined volume groups"
    | _ -> `Error "VG metadata contains multiple volume groups" ) >>= fun name ->
  expect_mapped_struct name vg >>= fun alist ->
  expect_mapped_string "id" alist >>= fun id ->
  Uuid.of_string id >>= fun id ->
  expect_mapped_int "seqno" alist >>= fun seqno ->
  let seqno = Int64.to_int seqno in
  map_expected_mapped_array "status" 
    (fun a -> let open Result in expect_string "status" a >>= fun x ->
              status_of_string x) alist >>= fun status ->
  expect_mapped_int "extent_size" alist >>= fun extent_size ->
  expect_mapped_int "max_lv" alist >>= fun max_lv ->
  let max_lv = Int64.to_int max_lv in
  expect_mapped_int "max_pv" alist >>= fun max_pv ->
  let max_pv = Int64.to_int max_pv in
  expect_mapped_struct "physical_volumes" alist >>= fun pvs ->
  ( match expect_mapped_struct "logical_volumes" alist with
    | `Ok lvs -> `Ok lvs
    | `Error _ -> `Ok [] ) >>= fun lvs ->
  let open IO in
  all (Lwt_list.map_s (fun (a,_) ->
    let open IO.FromResult in
    expect_mapped_struct a pvs >>= fun x ->
    let open IO in
    Pv.read a x
  ) pvs) >>= fun pvs ->
  all (Lwt_list.map_s (fun (a,_) ->
    let open IO.FromResult in
    expect_mapped_struct a lvs >>= fun x ->
    Lwt.return (Lv.of_metadata a x)
  ) lvs) >>= fun lvs ->

  (* Now we need to set up the free space structure in the PVs *)
  let free_space = List.flatten (List.map (fun pv -> Allocator.create pv.Pv.name pv.Pv.pe_count) pvs) in

  let free_space = List.fold_left (fun free_space lv -> 
    let lv_allocations = Lv.allocation_of_lv lv in
    debug "Allocations for lv %s:\n%s\n" lv.Lv.name (Allocator.to_string lv_allocations);
    Allocator.alloc_specified_areas free_space lv_allocations) free_space lvs in
 (* 
  let got_redo_lv = List.exists (fun lv -> lv.Lv.name = Constants.redo_log_lv_name) lvs in
  let redo_lv = if got_redo_lv then Some Constants.redo_log_lv_name else None in
 *)
  let ops = [] in
  let vg = { name; id; seqno; status; extent_size; max_lv; max_pv; pvs; lvs;  free_space; ops } in
  (*
  if got_redo_lv then apply_redo vg else return vg
  *)
  return vg

let create_new name devices_and_names =
  let open IO in
  let rec write_pv acc = function
    | [] -> return (List.rev acc)
    | (dev, name) :: pvs ->
      Pv.format dev name >>= fun pv ->
      write_pv (pv :: acc) pvs in
  write_pv [] devices_and_names >>= fun pvs ->
  debug "PVs created";
  let free_space = List.flatten (List.map (fun pv -> Allocator.create pv.Pv.name pv.Pv.pe_count) pvs) in
  let vg = { name; id=Uuid.create (); seqno=1; status=[Read; Write];
    extent_size=Constants.extent_size_in_sectors; max_lv=0; max_pv=0; pvs;
    lvs=[]; free_space; ops=[]; } in
  write vg true >>= fun _ ->
  debug "VG created";
  return ()

let parse buf =
  let text = Cstruct.to_string buf in
  let lexbuf = Lexing.from_string text in
  of_metadata (Lvmconfigparser.start Lvmconfiglex.lvmtok lexbuf)

open IO
let load = function
| [] -> Lwt.return (`Error "Vg.load needs at least one device")
| devices ->
  debug "Vg.load";
  IO.FromResult.all (Lwt_list.map_s Pv.read_metadata devices) >>= fun md ->
  parse (List.hd md)

let set_dummy_mode base_dir mapper_name full_provision =
  Constants.dummy_mode := true;
  Constants.dummy_base := base_dir;
  Constants.mapper_name := mapper_name;
  Constants.full_provision := full_provision




