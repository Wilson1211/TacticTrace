(* Embedded after exportTrace.ml and before instrumented proof code. Reads
   the settings file named by --tactictrace-config and applies it before any
   proof runs. The file is data; nothing in it is evaluated as OCaml. *)
unset_jrh_lexer;;

(* The first line of the settings file. It is also written to the acceptance
   file, and is the string the runner looks for inside a compiled proof to
   tell whether that proof can read settings at all. *)
let sampling_config_header = "tactictrace-sampling-config";;

let () =
  let fail message = invalid_arg ("tactictrace runtime config: " ^ message) in
  let quota value =
    if value = "" || (String.length value > 1 && value.[0] = '0') ||
       not (String.for_all (fun c -> c >= '0' && c <= '9') value) then
      fail "a quota must be a canonical nonnegative decimal integer";
    try int_of_string value with Failure _ -> fail "a quota is too large" in
  let read_config path =
    let channel = open_in_bin path in
    let lines = Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      let rec read acc = match input_line channel with
        | line ->
          if String.contains line '\r' || String.contains line '\000' then
            fail "carriage returns and NUL bytes are not supported";
          read (line :: acc)
        | exception End_of_file -> List.rev acc in
      read []) in
    let config : ExportTrace.sampling_config = match lines with
      | [header; output_root; quotas; backfill]
        when header = sampling_config_header ->
        let defaults = ExportTrace.default_sampling_config in
        let bucket_quotas = if quotas = "" then defaults.bucket_quotas else
          Array.of_list (List.map quota (String.split_on_char ',' quotas)) in
        let backfill = match backfill with
          | "0" -> false | "1" -> true
          | _ -> fail "backfill flag must be 0 or 1" in
        { output_root = if output_root = "" then None else Some output_root;
          bucket_quotas; backfill }
      | _ ->
        fail "expected a tactictrace-sampling-config header and three settings lines" in
    ExportTrace.configure_sampling config;
    (* Create the acceptance file exclusively, so a leftover one cannot make a
       run look configured. Settings are applied first, which means malformed
       settings stop the program before any proof code runs. *)
    let acceptance = open_out_gen [Open_wronly; Open_creat; Open_excl; Open_binary]
      0o600 (path ^ ".accepted") in
    Fun.protect ~finally:(fun () -> close_out acceptance) (fun () ->
      output_string acceptance (sampling_config_header ^ "\n")) in
  let rec find_config config = function
    | [] -> config
    | "--tactictrace-config" :: path :: rest ->
      if config <> None then fail "duplicate --tactictrace-config argument";
      find_config (Some path) rest
    | ["--tactictrace-config"] -> fail "missing --tactictrace-config path"
    | _ :: rest -> find_config config rest in
  match find_config None (Array.to_list Sys.argv) with
  | None -> ()
  | Some path -> read_config path;;

set_jrh_lexer;;
