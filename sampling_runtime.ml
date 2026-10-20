(* Embed after exportTrace.ml and before instrumented proof code. The runner
   appends --tactictrace-config PATH; PATH is data, never OCaml source. *)
unset_jrh_lexer;;

let sampling_runtime_capability = "tactictrace-config-v2:explicit-noexec-probe";;

let sampling_runtime_arguments =
  let fail message = invalid_arg ("tactictrace runtime config: " ^ message) in
  let decimal name value =
    if value = "" || (String.length value > 1 && value.[0] = '0') ||
       not (String.for_all (fun c -> c >= '0' && c <= '9') value) then
      fail (name ^ " must be a canonical nonnegative decimal integer");
    let parsed = try Int64.of_string value with Failure _ ->
      fail (name ^ " is too large") in
    if parsed > 2147483647L then fail (name ^ " exceeds 2147483647");
    parsed in
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
      | ["tactictrace-config-v2"; policy; seed; output_root; quotas; backfill; mode] ->
        if policy <> "stratified-reservoir" then
          fail "sampling policy must be stratified-reservoir";
        let defaults = ExportTrace.default_sampling_config in
        let bucket_quotas = if quotas = "" then defaults.bucket_quotas else
          Array.of_list (List.map
            (fun text -> Int64.to_int (decimal "quota" text))
            (String.split_on_char ',' quotas)) in
        let backfill = match backfill with
          | "0" -> false | "1" -> true
          | _ -> fail "backfill flag must be 0 or 1" in
        if mode <> "deterministic" && mode <> "random" then
          fail "selection mode must be deterministic or random";
        let seed = decimal "seed" seed in
        if mode = "deterministic" && seed <> 0L then
          fail "a seed applies only in random mode";
        { policy; seed;
          output_root = if output_root = "" then None else Some output_root;
          bucket_quotas; selection_mode = mode; backfill }
      | _ -> fail "expected exactly seven tactictrace-config-v2 lines" in
    ExportTrace.configure_sampling config;
    (* Exclusive acknowledgement prevents a stale file from claiming success.
       This happens before proof code, so malformed settings cannot run a proof. *)
    let receipt = open_out_gen [Open_wronly; Open_creat; Open_excl; Open_binary]
      0o600 (path ^ ".accepted") in
    Fun.protect ~finally:(fun () -> close_out receipt) (fun () ->
      output_string receipt (sampling_runtime_capability ^ "\n")) in
  let rec parse config kept = function
    | [] -> (config, List.rev kept)
    | "--tactictrace-config" :: path :: rest ->
      if config <> None then fail "duplicate --tactictrace-config argument";
      parse (Some path) kept rest
    | ["--tactictrace-config"] -> fail "missing --tactictrace-config path"
    | argument :: rest -> parse config (argument :: kept) rest in
  let config, arguments = parse None [] (Array.to_list Sys.argv) in
  (match config with None -> () | Some path -> read_config path);
  Array.of_list arguments;;

set_jrh_lexer;;
