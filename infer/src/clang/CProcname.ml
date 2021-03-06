(*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd

let rec get_mangled_method_name function_decl_info method_decl_info =
  (* For virtual methods return mangled name of the method from most base class
     Go recursively until there is no method in any parent class. All names
     of the same method need to be the same, otherwise dynamic dispatch won't
     work. *)
  let open Clang_ast_t in
  match method_decl_info.xmdi_overriden_methods with
  | [] -> function_decl_info.fdi_mangled_name
  | base1_dr :: _ ->
      (let base1 = match CAst_utils.get_decl base1_dr.dr_decl_pointer with
          | Some b -> b
          | _ -> assert false in
       match base1 with
       | CXXMethodDecl (_, _, _, fdi, mdi)
       | CXXConstructorDecl (_, _, _, fdi, mdi)
       | CXXConversionDecl (_, _, _, fdi, mdi)
       | CXXDestructorDecl (_, _, _, fdi, mdi) ->
           get_mangled_method_name fdi mdi
       | _ -> assert false)

let mk_c_function translation_unit_context name function_decl_info_opt =
  let file =
    match function_decl_info_opt with
    | Some (decl_info, function_decl_info) ->
        (match function_decl_info.Clang_ast_t.fdi_storage_class with
         | Some "static" ->
             let file_opt = (fst decl_info.Clang_ast_t.di_source_range).Clang_ast_t.sl_file in
             Option.value_map ~f:SourceFile.to_string ~default:"" file_opt
         | _ -> "")
    | None -> "" in
  let mangled_opt = match function_decl_info_opt with
    | Some (_, function_decl_info) -> function_decl_info.Clang_ast_t.fdi_mangled_name
    | _ -> None in
  let mangled_name = match mangled_opt with
    | Some m when CGeneral_utils.is_cpp_translation translation_unit_context -> m
    | _ -> "" in
  let mangled = (Utils.string_crc_hex32 file) ^ mangled_name in
  if String.is_empty file && String.is_empty mangled_name then
    Procname.from_string_c_fun name
  else
    Procname.C (Procname.c name mangled)

let mk_cpp_method class_name method_name ?meth_decl mangled =
  let method_kind = match meth_decl with
    | Some (Clang_ast_t.CXXConstructorDecl (_, _, _, _, {xmdi_is_constexpr})) ->
        Procname.CPPConstructor (mangled, xmdi_is_constexpr)
    | _ ->
        Procname.CPPMethod mangled in
  Procname.ObjC_Cpp
    (Procname.objc_cpp class_name method_name method_kind)

let mk_objc_method class_typename method_name method_kind =
  Procname.ObjC_Cpp
    (Procname.objc_cpp class_typename method_name method_kind)

let block_procname_with_index defining_proc i =
  Config.anonymous_block_prefix ^
  (Procname.to_string defining_proc) ^
  Config.anonymous_block_num_sep ^
  (string_of_int i)

(* Global counter for anonymous block*)
let block_counter = ref 0

let get_next_block_pvar defining_proc =
  let name = block_procname_with_index defining_proc (!block_counter +1) in
  Pvar.mk_tmp name defining_proc

let reset_block_counter () =
  block_counter := 0

let get_fresh_block_index () =
  block_counter := !block_counter +1;
  !block_counter

let mk_fresh_block_procname defining_proc =
  let name = block_procname_with_index defining_proc (get_fresh_block_index ()) in
  Procname.mangled_objc_block name


let get_class_typename method_decl_info =
  let class_ptr = Option.value_exn method_decl_info.Clang_ast_t.di_parent_pointer in
  match CAst_utils.get_decl class_ptr with
  | Some class_decl -> CType_decl.get_record_typename class_decl
  | None -> assert false

module NoAstDecl = struct
  let c_function_of_string translation_unit_context name =
    mk_c_function translation_unit_context name None

  let cpp_method_of_string class_name method_name =
    mk_cpp_method class_name method_name None

  let objc_method_of_string_kind class_name method_name method_kind =
    mk_objc_method class_name method_name method_kind
end


let from_decl translation_unit_context meth_decl =
  let open Clang_ast_t in
  match meth_decl with
  | FunctionDecl (decl_info, name_info, _, fdi) ->
      let name = CAst_utils.get_qualified_name name_info in
      let function_info = Some (decl_info, fdi) in
      mk_c_function translation_unit_context name function_info
  | CXXMethodDecl (decl_info, name_info, _, fdi, mdi)
  | CXXConstructorDecl (decl_info, name_info, _, fdi, mdi)
  | CXXConversionDecl (decl_info, name_info, _, fdi, mdi)
  | CXXDestructorDecl (decl_info, name_info, _, fdi, mdi) ->
      let mangled = get_mangled_method_name fdi mdi in
      let method_name = CAst_utils.get_unqualified_name name_info in
      let class_typename = get_class_typename decl_info in
      mk_cpp_method class_typename method_name ~meth_decl mangled
  | ObjCMethodDecl (decl_info, name_info, mdi) ->
      let class_typename = get_class_typename decl_info in
      let method_name = name_info.Clang_ast_t.ni_name in
      let is_instance = mdi.Clang_ast_t.omdi_is_instance_method in
      let method_kind = Procname.objc_method_kind_of_bool is_instance in
      mk_objc_method class_typename method_name method_kind
  | BlockDecl _ ->
      let name = Config.anonymous_block_prefix ^ Config.anonymous_block_num_sep ^
                 (string_of_int (get_fresh_block_index ())) in
      Procname.mangled_objc_block name
  | _ -> assert false
