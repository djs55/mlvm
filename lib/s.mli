(*
 * Copyright (C) 2013 Citrix Systems Inc.
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

module type PRINT = sig
  type t
  val to_string: t -> string
end

module type MARSHAL = sig
  type t
  val marshal: t -> Cstruct.t -> Cstruct.t
end

module type UNMARSHAL = sig
  type t
  val unmarshal: Cstruct.t -> (t * Cstruct.t, string) Result.result
end

module type EQUALS = sig
  type t
  val equals: t -> t -> bool
end

module type RPC = sig
  type t
  val t_of_rpc: Rpc.t -> t
  val rpc_of_t: t -> Rpc.t
end

module type VOLUME = sig
  type t
  type tag
  type name
  type size

  val create: t -> name -> int64 -> (t, string) Result.result

  val rename: t -> name -> name -> (t, string) Result.result

  val resize: t -> name -> size -> (t, string) Result.result

  val remove: t -> name -> (t, string) Result.result

  val add_tag: t -> name -> tag -> (t, string) Result.result

  val remove_tag: t -> name -> tag -> (t, string) Result.result
end

