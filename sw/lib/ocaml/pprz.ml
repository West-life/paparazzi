(*
 * $Id$
 *
 * Downlink protocol (handling messages.xml)
 *  
 * Copyright (C) 2003 Pascal Brisset, Antoine Drouin
 *
 * This file is part of paparazzi.
 *
 * paparazzi is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2, or (at your option)
 * any later version.
 *
 * paparazzi is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with paparazzi; see the file COPYING.  If not, write to
 * the Free Software Foundation, 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA. 
 *
 *)

open Printf


type message_id = int
type ac_id = int
type class_name = string
type format = string
type _type = 
    Scalar of string
  | ArrayType of string
type value =
    Int of int | Float of float | String of string | Int32 of int32
  | Array of value array
type field = {
    _type : _type;
    fformat : format;
  }

type message = {
    name : string; (** Lowercase *)
    fields : (string * field) list
  }

type type_descr = {
    format : string ;
    glib_type : string;
    inttype : string;
    size : int;
    value : value
  }

type values = (string * value) list

type payload = string


let separator = ","
let regexp_separator = Str.regexp ","
let split_array = fun s -> Str.split regexp_separator s

let (//) = Filename.concat
let lazy_messages_xml = lazy (Xml.parse_file (Env.paparazzi_src // "conf" // "messages.xml"))
let messages_xml = fun () -> Lazy.force lazy_messages_xml

external float_of_bytes : string -> int -> float = "c_float_of_indexed_bytes"
external int32_of_bytes : string -> int -> int32 = "c_int32_of_indexed_bytes"
external int8_of_bytes : string -> int -> int = "c_int8_of_indexed_bytes"
external int16_of_bytes : string -> int -> int = "c_int16_of_indexed_bytes"
external sprint_float : string -> int -> float -> unit = "c_sprint_float"
external sprint_int32 : string -> int -> int32 -> unit = "c_sprint_int32"
external sprint_int16 : string -> int -> int -> unit = "c_sprint_int16"

let types = [
  ("uint8",  { format = "%u"; glib_type = "guint8"; inttype = "uint8_t";  size = 1; value=Int 42 });
  ("uint16", { format = "%u";  glib_type = "guint16"; inttype = "uint16_t"; size = 2; value=Int 42 });
  ("uint32", { format = "%lu" ;  glib_type = "guint32"; inttype = "uint32_t"; size = 4; value=Int 42 });
  ("int8",   { format = "%d"; glib_type = "gint8"; inttype = "int8_t";   size = 1; value= Int 42 });
  ("int16",  { format = "%d";  glib_type = "gint16"; inttype = "int16_t";  size = 2; value= Int 42 });
  ("int32",  { format = "%ld" ;  glib_type = "gint32"; inttype = "int32_t";  size = 4; value=Int 42 });
  ("float",  { format = "%f" ;  glib_type = "gfloat"; inttype = "float";  size = 4; value=Float 4.2 });
  ("string",  { format = "%s" ;  glib_type = "gchar*"; inttype = "char*";  size = max_int; value=String "42" })
]

let is_array_type = fun s -> 
  let n = String.length s in
  n >= 2 && String.sub s (n-2) 2 = "[]"

let type_of_array_type = fun s ->
  let n = String.length s in
  String.sub s 0 (n-2)

let int_of_string = fun x ->
  try int_of_string x with
    _ -> failwith (sprintf "Pprz.int_of_string: %s" x)

let rec value = fun t v ->
  match t with 
    Scalar ("uint8" | "uint16" | "int8" | "int16") -> Int (int_of_string v)
  | Scalar ("uint32" | "int32") -> Int32 (Int32.of_string v)
  | Scalar "float" -> Float (float_of_string v)
  | Scalar "string" -> String v
  | ArrayType t' ->
      Array (Array.map (value (Scalar t')) (Array.of_list (split_array v)))
  | Scalar t -> failwith (sprintf "Pprz.value: Unexpected type: %s" t)


let rec string_of_value = function
    Int x -> string_of_int x
  | Float x -> string_of_float x
  | Int32 x -> Int32.to_string x
  | String s -> s
  | Array a -> String.concat separator (Array.to_list (Array.map string_of_value a))


let magic = fun x -> (Obj.magic x:('a,'b,'c) Pervasives.format)


let formatted_string_of_value = fun format v ->
  match v with
    Float x -> sprintf (magic format) x
  | v -> string_of_value v


let sizeof = fun f ->
  match f with
    Scalar t -> (List.assoc t types).size
  | ArrayType t -> failwith "sizeof: Array"
let size_of_field = fun f -> sizeof f._type
let default_format = function
    Scalar x | ArrayType x ->
      try (List.assoc x types).format with
	Not_found -> failwith (sprintf "Unknown format '%s'" x)
let default_value = fun x ->
  match x with
    Scalar t -> (List.assoc t types).value
  | ArrayType t -> failwith "default_value: Array"

let payload_size_of_message = fun message ->
  List.fold_right
    (fun (_, f) s -> size_of_field f + s)
    message.fields
    2 (** + message id + aircraft id *)

let field_of_xml = fun xml ->
  let t = ExtXml.attrib xml "type" in
  let t = if is_array_type t then ArrayType (type_of_array_type t) else Scalar t in
  let f = try Xml.attrib xml "format" with _ -> default_format t in
  (String.lowercase (ExtXml.attrib xml "name"), { _type = t; fformat = f })

let string_of_values = fun vs ->
  String.concat " " (List.map (fun (a,v) -> sprintf "%s=%s" a (string_of_value v)) vs)

let assoc = fun a vs -> 
  try List.assoc (String.lowercase a) vs with Not_found -> 
    failwith (sprintf "Attribute '%s' not found in '%s'" a (string_of_values vs))

let float_assoc = fun (a:string) vs -> 
  match assoc a vs with
    Float x -> x
  | _ -> invalid_arg "Pprz.float_assoc"

let int_assoc = fun (a:string) vs -> 
  match assoc a vs with
    Int x -> x
  | _ -> invalid_arg "Pprz.int_assoc"

let int32_assoc = fun (a:string) vs -> 
  match assoc a vs with
    Int32 x -> x
  | _ -> invalid_arg "Pprz.int_assoc"

let string_assoc = fun (a:string) (vs:values) -> string_of_value (assoc a vs)



(** Table of msg classes indexed by name. Each class is a table of messages
   indexed by ids *)
let lazy_classes =
  lazy
    (let h = Hashtbl.create 13 in
    List.iter
      (fun xml_class ->
	let by_id = Hashtbl.create 13
	and by_name = Hashtbl.create 13 in
	List.iter
	  (fun xml_msg ->
	    let name = ExtXml.attrib xml_msg "name" in
	    let msg = {
	      name = name;
	      fields = List.map field_of_xml (Xml.children xml_msg)
	    } in
	    let id = int_of_string (ExtXml.attrib xml_msg "id") in
	    if Hashtbl.mem by_id id then
	      failwith (sprintf "Duplicated id in messages.xml: %d" id);
	    Hashtbl.add by_id id msg;
	    Hashtbl.add by_name name (id, msg))
	  (Xml.children xml_class);
	Hashtbl.add h (ExtXml.attrib xml_class "name") (by_id, by_name)
      )
      (Xml.children (messages_xml ()));
    h)

let classes = fun () -> Lazy.force lazy_classes
    
(** Returns a value and its length *)
let rec value_of_bin = fun buffer index _type ->
  match _type with
    Scalar "uint8" -> Int (Char.code buffer.[index]), sizeof _type
  | Scalar "int8" -> Int (int8_of_bytes buffer index), sizeof _type
  | Scalar "uint16" -> Int (Char.code buffer.[index+1] lsl 8 + Char.code buffer.[index]), sizeof _type
  | Scalar "int16" -> Int (int16_of_bytes buffer index), sizeof _type
  | Scalar "float" ->  Float (float_of_bytes buffer index), sizeof _type
  | Scalar ("int32"  | "uint32") -> Int32 (int32_of_bytes buffer index), sizeof _type
  | ArrayType t ->
      (** First get the number of values *)
      let n = int8_of_bytes buffer index in
      let type_of_elt = Scalar t in
      let s = sizeof type_of_elt in
      let size = 1 + n * s in
      (Array (Array.init n 
	       (fun i -> fst (value_of_bin buffer (index+1+i*s) type_of_elt))), size)
  | _ -> failwith "value_of_bin"

let value_field = fun buf index field ->
  value_of_bin buf index field._type

let byte = fun x -> Char.chr (x land 0xff)

(** Returns the size of outputed data *)
let rec sprint_value = fun buf i _type v ->
  match _type, v with
    Scalar ("int8"|"uint8"), Int x ->
      if x < 0 || x > 0xff then
	failwith (sprintf "Value too large to fit in a (u)int8: %d" x);
      buf.[i] <- Char.chr x; sizeof _type
  | Scalar "float", Float f -> sprint_float buf i f; sizeof _type
  | Scalar "int32", Int32 x -> sprint_int32 buf i x; sizeof _type
  | Scalar "int16", Int x -> sprint_int16 buf i x; sizeof _type
  | Scalar ("int32" | "uint32"), Int value ->
      assert (_type <> Scalar "uint32" || value >= 0);
      buf.[i+3] <- byte (value asr 24);
      buf.[i+2] <- byte (value lsr 16);
      buf.[i+1] <- byte (value lsr 8);
      buf.[i+0] <- byte value;
      sizeof _type
  | Scalar "uint16", Int value ->
      assert (value >= 0);
      buf.[i+1] <- byte (value lsr 8);
      buf.[i+0] <- byte value;
      sizeof _type
  | ArrayType t, Array values ->
      (** Put the size first, then the values *)
      let n = Array.length values in
      sprint_value buf i (Scalar "uint8") (Int n);
      let type_of_elt = Scalar t in
      let s = sizeof type_of_elt in
      for j = 0 to n - 1 do
	sprint_value buf (i+1+j*s) type_of_elt values.(j)
      done;
      1 + n * s
  | (Scalar x|ArrayType x), _ -> failwith (sprintf "Pprz.sprint_value (%s)" x)
  
  

module type CLASS = sig val name : string end

exception Unknown_msg_name of string * string

module Transport = struct
  let stx = Char.chr 0x99 (** sw/airborne/downlink.h *)
  let offset_length = 1
  let offset_payload = 2

  let index_start = fun buf ->
    String.index buf stx

  let length = fun buf start ->
    let len = String.length buf - start in
    if len > offset_length then
      let l = Char.code buf.[start+offset_length] in
      Debug.call 'T' (fun f -> fprintf f "Pprz len=%d\n" l);
      max l 4 (** if l<4 (4=stx+length+ck_a+ck_b), it's not a valid length *)
    else
      raise Serial.Not_enough

  let (+=) = fun r x -> r := (!r + x) land 0xff
  let compute_checksum = fun msg ->
    let l = String.length msg in
    let ck_a = ref 0  and ck_b = ref 0 in
    for i = 1 to l - 3 do
      ck_a += Char.code msg.[i];
      ck_b += !ck_a
    done;
    !ck_a, !ck_b

  let checksum = fun msg ->
    let l = String.length msg in
    let ck_a, ck_b = compute_checksum msg in
    Debug.call 'T' (fun f -> fprintf f "Pprz cs: %d %d\n" ck_a (Char.code msg.[l-2]));
    ck_a = Char.code msg.[l-2] && ck_b = Char.code msg.[l-1]

  let payload = fun msg ->
    let l = String.length msg in
    assert(Char.code msg.[offset_length] = l);
    assert(l >= 4);
    Serial.payload_of_string (String.sub msg offset_payload (l-4))

  let packet = fun payload ->
    let payload = Serial.string_of_payload payload in
    let n = String.length payload in
    let msg_length = n + 4 in (** + stx, len, ck_a and ck_b *)
    let m = String.create msg_length in
    String.blit payload 0 m offset_payload n;
    m.[0] <- stx;
    m.[offset_length] <- Char.chr msg_length;
    let (ck_a, ck_b) = compute_checksum m in
    m.[msg_length-2] <- Char.chr ck_a;
    m.[msg_length-1] <- Char.chr ck_b;
    m
end

let offset_ac_id = 0
let offset_msg_id = 1
let offset_fields = 2

module Messages(Class:CLASS) = struct
  let max_length = 256
  let messages_by_id, messages_by_name = 
    try
      Hashtbl.find (classes ()) Class.name
    with
      Not_found -> failwith (sprintf "Unknown message class: %s" Class.name)
  let message_of_id = fun id -> Hashtbl.find messages_by_id id
  let message_of_name = fun name ->
    try
      Hashtbl.find messages_by_name name
    with
      Not_found -> raise (Unknown_msg_name (name, Class.name))


  let values_of_payload = fun buffer ->
    let buffer = Serial.string_of_payload buffer in
    let id = Char.code buffer.[offset_msg_id] in
    let ac_id = Char.code buffer.[offset_ac_id] in
    let message = message_of_id id in
    Debug.call 'T' (fun f -> fprintf f "Pprz.values id=%d\n" id);
    let rec loop = fun index fields ->
      match fields with
	[] -> []
      | (field_name, field_descr)::fs -> 
	  let (value, n) = value_field buffer index field_descr in
	  (field_name, value) :: loop (index+n) fs in
    (id, ac_id, loop offset_fields message.fields)


  let payload_of_values = fun id ac_id values ->
    let message = message_of_id id in

    (** The actual length is computed from the values *)
    let p = String.make max_length '#' in

    p.[offset_msg_id] <- Char.chr id;
    p.[offset_ac_id] <- Char.chr ac_id;
    let i = ref offset_fields in
    List.iter
      (fun (field_name, field) ->
	let v =
	  try List.assoc field_name values with
	    Not_found -> default_value field._type in
	let size = sprint_value p !i field._type v in
	i := !i + size
	)
      message.fields;
    
    (** Cut to the actual length *)
    let p = String.sub p 0 !i in
    Serial.payload_of_string p
   

  let space = Str.regexp "[ \t]+"
  let values_of_string = fun s ->
    match Str.split space s with
      msg_name::args ->
	begin
	  try
	    let msg_id, msg = message_of_name msg_name in
	    let values = List.map2 (fun (field_name, field) v -> (field_name, value field._type v)) msg.fields args in
	    (msg_id, values)
	  with
	    Invalid_argument "List.map2" -> failwith (sprintf "Pprz.values_of_string: '%s'" s)
	end
    | [] -> invalid_arg (sprintf "Pprz.values_of_string: %s" s)

  let string_of_message = fun ?(sep=" ") msg values ->
    (** Check that the values are compatible with this message *)
    List.iter 
      (fun (k, _) ->
	if not (List.mem_assoc k msg.fields) 
	then invalid_arg (sprintf "Pprz.string_of_message: unknown field '%s' in message '%s'" k msg.name))
      values;

    String.concat sep
      (msg.name::
       List.map 
	 (fun (field_name, field) ->
	   let v =
	     try List.assoc field_name values with
	       Not_found ->
		 default_value field._type in
	   formatted_string_of_value field.fformat v)
	 msg.fields)

  let message_send = fun sender msg_name values ->
    let m = snd (message_of_name msg_name) in
    let s = string_of_message m values in
    Ivy.send (sprintf "%s %s" sender s)

  let message_bind = fun ?sender msg_name cb ->
    match sender with
      None ->
	Ivy.bind (fun _ args -> cb args.(0) (snd (values_of_string args.(1)))) (sprintf "^([^ ]*) +(%s .*)" msg_name)
    | Some s ->
	Ivy.bind (fun _ args -> cb s (snd (values_of_string args.(0)))) (sprintf "^%s +(%s .*)" s msg_name)
	  

  let message_answerer = fun sender msg_name cb ->
    let ivy_cb = fun _ args ->
      let asker = args.(0)
      and asker_id = args.(1) in
      try (** Against [cb] exceptions *)
	let values = cb asker (snd (values_of_string args.(2))) in
	let m = string_of_message (snd (message_of_name msg_name)) values in
	Ivy.send (sprintf "%s %s %s" asker_id sender m)
      with
	exc -> fprintf stderr "Pprz.answerer %s:%s: %s\n%!" sender msg_name (Printexc.to_string exc)
    in
    Ivy.bind ivy_cb (sprintf "^([^ ]*) +([^ ]*) +(%s_REQ.*)" msg_name)

  let gen_id = let r = ref 0 in fun () -> incr r; !r
  let message_req = fun sender msg_name values (f:string -> (string * value) list -> unit) ->
    let b = ref (Obj.magic ()) in
    let cb = fun _ args ->
      Ivy.unbind !b;
      f args.(0) (snd (values_of_string args.(1))) in
    let id = sprintf "%d_%d" (Unix.getpid ()) (gen_id ()) in
    let r = sprintf "^%s ([^ ]*) +(%s.*)" id msg_name in
    b := Ivy.bind cb r;
    let msg_name_req = msg_name ^ "_REQ" in
    let m = sprintf "%s %s %s" sender id (string_of_message (snd (message_of_name msg_name_req)) values) in
    Ivy.send m
end
