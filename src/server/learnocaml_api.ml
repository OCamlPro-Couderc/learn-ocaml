(* This file is part of Learn-OCaml.
 *
 * Copyright (C) 2018 OCamlPro.
 *
 * Learn-OCaml is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Learn-OCaml is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>. *)

type 'a token = Learnocaml_sync.Token.t

type student
type teacher

module Student = struct

  type t = {
    token: student token;
    nickname: string option;
    results: (float * int option) Learnocaml_sync.Map.t;
    tags: string list;
  }

  let enc =
    let open Json_encoding in
    obj4
      (req "token" string)
      (opt "nickname" string)
      (dft "results" (assoc (tup2 float (option int))) [])
      (dft "tags" (list string) [])
    |> conv
      (fun t ->
         Learnocaml_sync.Token.to_string t.token,
         t.nickname, Learnocaml_sync.Map.bindings t.results, t.tags)
      (fun (token, nickname, results, tags) -> {
           token = Learnocaml_sync.Token.parse token;
           nickname;
           results =
             List.fold_left (fun m (s, r) -> Learnocaml_sync.Map.add s r m)
               Learnocaml_sync.Map.empty
               results;
           tags;
         })
end

type _ request =
  | Static: string list -> string request
  | Version: unit -> string request
  | Create_token: student token option -> student token request
  | Create_teacher_token: teacher token -> teacher token request
  | Fetch_save: 'a token -> Learnocaml_sync.save_file request
  | Update_save:
      'a token * Learnocaml_sync.save_file ->
      Learnocaml_sync.save_file request
  | Exercise_index: 'a token -> Learnocaml_index.group_contents request
  | Students_list: teacher token -> Student.t list request
  | Static_json: string * 'a Json_encoding.encoding -> 'a request
  (** [Static_json] is to help transition: do not use *)
  | Invalid_request: string -> string request

type http_request = {
  meth: [ `GET | `POST of string];
  path: string list;
}

module type JSON_CODEC = sig
  val decode: 'a Json_encoding.encoding -> string -> 'a
  val encode: 'a Json_encoding.encoding -> 'a -> string
end

module Conversions (Json: JSON_CODEC) = struct

  let response_codec
    : type resp.
      resp request -> (resp -> string) * (string -> resp)
    = fun req ->
      let str = (fun x -> x), (fun x -> x) in
      let json enc = (Json.encode enc), (Json.decode enc) in
      let ( +> ) (cod, decod) (cod', decod') =
        (fun x -> cod (cod' x)),
        (fun s -> decod' (decod s))
      in
      match req with
      | Static _ -> str
      | Version _ -> json Json_encoding.(obj1 (req "version" string))
      | Create_token _ ->
          json Json_encoding.(obj1 (req "token" string)) +>
          Learnocaml_sync.Token.(to_string, parse)
      | Create_teacher_token _ ->
          json Json_encoding.(obj1 (req "token" string)) +>
          Learnocaml_sync.Token.(to_string, parse)
      | Fetch_save _ ->
          json Learnocaml_sync.save_file_enc
      | Update_save _ ->
          json Learnocaml_sync.save_file_enc
      | Exercise_index _ ->
          json Learnocaml_index.exercise_index_enc
      | Students_list _ ->
          json Json_encoding.(list Student.enc)
      | Static_json (_, enc) ->
          json enc
      | Invalid_request _ ->
          str

  let response_encode r = fst (response_codec r)
  let response_decode r = snd (response_codec r)

  let to_http_request
    : type resp. resp request -> http_request
    = function
      | Static path ->
          { meth = `GET; path }
      | Version () ->
          { meth = `GET; path = ["version"] }
      | Create_token tok_opt ->
          let arg = match tok_opt with
            | Some t -> [Learnocaml_sync.Token.to_string t]
            | None -> []
          in
          { meth = `GET; path = "sync" :: "gimme" :: arg }
      | Create_teacher_token token ->
          assert (Learnocaml_sync.Token.is_teacher token);
          let stoken = Learnocaml_sync.Token.to_string token in
          { meth = `GET; path = ["teacher"; stoken; "gen"] }
      | Fetch_save token ->
          let stoken = Learnocaml_sync.Token.to_string token in
          { meth = `GET; path = ["sync"; stoken] }
      | Update_save (token, save) ->
          let stoken = Learnocaml_sync.Token.to_string token in
          let body = Json.encode Learnocaml_sync.save_file_enc save in
          { meth = `POST body; path = ["sync"; stoken] }
      | Exercise_index token ->
          let stoken = Learnocaml_sync.Token.to_string token in
          { meth = `GET; path = ["exercise-index"; stoken] }
      | Students_list token ->
          assert (Learnocaml_sync.Token.is_teacher token);
          let stoken = Learnocaml_sync.Token.to_string token in
          { meth = `GET; path = ["teacher"; stoken; "students"] }
      | Static_json (path, _) ->
          { meth = `GET; path = [path] }
      | Invalid_request s ->
          failwith ("Error request "^s)

end

module type REQUEST_HANDLER = sig
  type 'resp ret
  val map_ret: ('a -> 'b) -> 'a ret -> 'b ret

  val callback: 'resp request -> 'resp ret
end

module Server (Json: JSON_CODEC) (Rh: REQUEST_HANDLER) = struct

  module C = Conversions(Json)

  let handler request =
      let k req =
        Rh.callback req |> Rh.map_ret (C.response_encode req)
      in
      match request with
      | { meth = `GET; path = [] } ->
          Static ["index.html"] |> k
      | { meth = `GET; path = ["version"] } ->
          Version () |> k
      | { meth = `GET; path = ["sync"; "gimme"] } ->
          Create_token None |> k
      | { meth = `GET; path = ["sync"; "gimme"; token] } ->
          (match Learnocaml_sync.Token.parse token with
           | token -> Create_token (Some token) |> k
           | exception (Failure s) -> Invalid_request s |> k)
      | { meth = `GET; path = ["teacher"; token; "gen"] } ->
          (match Learnocaml_sync.Token.parse token with
           | token when Learnocaml_sync.Token.is_teacher token ->
               Create_teacher_token token |> k
           | _ -> Invalid_request "Unauthorised" |> k
           | exception (Failure s) -> Invalid_request s |> k)
      | { meth = `GET; path = ["sync"; token] } ->
          (match Learnocaml_sync.Token.parse token with
           | token -> Fetch_save token |> k
           | exception (Failure s) -> Invalid_request s |> k)
      | { meth = `POST body; path = ["sync"; token] } ->
          (match
             Learnocaml_sync.Token.parse token,
             Json.decode Learnocaml_sync.save_file_enc body
           with
           | token, save -> Update_save (token, save) |> k
           | exception (Failure s) -> Invalid_request s |> k
           | exception e -> Invalid_request (Printexc.to_string e) |> k)
      | { meth = `GET; path = ["exercise-index"; token] } ->
          (match Learnocaml_sync.Token.parse token with
           | token -> Exercise_index token |> k
           | exception (Failure s) -> Invalid_request s |> k)
      | { meth = `GET; path = ["teacher"; token; "students"] } ->
          (match Learnocaml_sync.Token.parse token with
           | token when Learnocaml_sync.Token.is_teacher token ->
               Students_list token |> k
           | _ -> Invalid_request "Unauthorised" |> k
           | exception (Failure s) -> Invalid_request s |> k)
      | { meth = `GET; path } ->
          (* FIXME: also handles the deprecated Static_json (they are the same,
             server-side). This is dirty *)
          Static path |> k
      | { meth = `POST _; path } ->
          Invalid_request (Printf.sprintf "POST %s" (String.concat "/" path))
          |> k

end

module Client (Json: JSON_CODEC) = struct

  open Lwt.Infix

  module C = Conversions(Json)

  let make_request
    : type resp.
      (http_request -> (string, 'b) result Lwt.t) ->
      resp request -> (resp, 'b) result Lwt.t
    = fun send req ->
      let http_request = C.to_http_request req in
      send http_request >|= function
      | Ok str -> Ok (C.response_decode req str)
      | Error e -> Error e

end

(*
let client: type resp. resp request -> resp result = fun req ->

  let query_enc = 
 function
  | Static str as req -> Server_caller.fetch (path req) |> query
*)

(* let server: meth * string list * string -> _ request = function
 *   | `GET, [] -> Static "index.json"
 *   | `GET, ["sync"; "gimme"] -> Create_token ()
 *   | `GET, ["sync"; token] -> Fetch_save token
 *   | `POST, ["sync"; token] -> *) 