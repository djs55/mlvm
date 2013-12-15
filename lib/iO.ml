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

open Lwt

type 'a io = ('a, string) Result.result Lwt.t 

let rec mkdir_p x =
  if Sys.file_exists x
  then ()
  else
    let parent = Filename.dirname x in
    if not(Sys.file_exists parent) then mkdir_p parent;
    Unix.mkdir x 0o0755

let dummy_fname dev ty =
  let dir = Filename.concat !Constants.dummy_base dev in
  mkdir_p dir;
  Filename.concat dir ty

let block_error = function
  | `Unknown x -> `Error x
  | `Unimplemented -> `Error "unimplemented"
  | `Is_read_only -> `Error "device is read-only"
  | `Disconnected -> `Error "disconnected"

let get_size device =
  if !Constants.dummy_mode
  then return (`Ok Constants.tib)
  else match Block.blkgetsize device with
    | `Ok x -> return (`Ok x)
    | `Error e -> return (`Error (block_error e))

(* Should we wrap in Result.result? *)
let with_file filename flags f =
  Lwt_unix.openfile filename flags 0o0 >>= fun fd ->
  Lwt.catch
    (fun () -> f () >>= fun x -> Lwt_unix.close fd >>= fun () -> return (`Ok x))
    (fun e -> Lwt_unix.close fd >>= fun () -> return (`Error (Printexc.to_string e)))

let get name device offset length =
  let filename = if !Constants.dummy_mode then dummy_fname device name else device in
  let offset = if !Constants.dummy_mode then 0L else offset in
  let buf = Cstruct.create length in
  with_file filename [ Lwt_unix.O_RDONLY ]
    (fun fd ->
      Lwt_unix.LargeFile.lseek fd offset Lwt_unix.SEEK_SET >>= fun () ->
      Block.really_read fd buf >>= fun () ->
      return buf)

let put name device offset buf =
  let filename = if !Constants.dummy_mode then dummy_fname device "pvh" else device in
  let flags = [ Lwt_unix.O_RDWR; Lwt_unix.O_DSYNC ] @ (if !Constants.dummy_mode then [ Lwt_unix.O_CREAT ] else []) in
  let offset = if !Constants.dummy_mode then 0L else offset in
  with_file filename flags
    (fun fd ->
      Lwt_unix.LargeFile.lseek fd offset Lwt_unix.SEEK_SET >>= fun () ->
      Block.really_write fd buf)

let get_label device =
  let length = if !Constants.dummy_mode then Constants.sector_size * 2 else Constants.label_scan_size in
  get "pvh" device 0L length

let put_label device offset buf =
  put "pvh" device offset buf

let get_mda_header device offset mda_header_size =
  get "mdah" device offset mda_header_size

let put_mda_header device offset buf =
  put "mdah" device offset buf

let ( >>= ) m f = m >>= function
  | `Error x -> return (`Error x)
  | `Ok x -> f x

let return x = return (`Ok x)

let get_md device offset offset' firstbit secondbit =
  get "md1" device offset firstbit >>= fun a ->
  get "md2" device offset' secondbit >>= fun b ->
  let buf = Cstruct.create (firstbit + secondbit) in
  Cstruct.blit a 0 buf 0 firstbit;
  Cstruct.blit b 0 buf firstbit secondbit;
  return buf

let put_md device offset offset' firstbitbuf secondbitbuf =
  put "md1" device offset firstbitbuf >>= fun () ->
  put "md2" device offset' secondbitbuf
