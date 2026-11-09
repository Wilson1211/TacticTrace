(* This file must be loaded inside HOL Light proof files *)

unset_jrh_lexer;;
module ExportTrace = struct
  type tac_record = {
    definition_line_number: string * int;
    user_line_number: string * int;
    goal_before: goal;
    goals_after: goal list;
    num_subgoals: int;
  }

  type conv_record = {
    definition_line_number: string * int;
    user_line_number: string * int;
    input: term;
    output: thm
  }

  (* Keep record_args separate so tactic records can render them lazily. *)
  type record_args = {
    names: string list;
    types: string list;
    values: string list;
    exprs: string list;
  }

  (***************************************************************************)
  (*        For sorting and pruning too large or uninteresting cases         *)
  (***************************************************************************)

  let is_term_too_large (t:term): bool =
    let maxcnt = 1000 in
    let rec fn (t:term): int =
      if is_numeral t then 1 else
      match t with
      | Comb(x,y) ->
        let cx = fn(x) in
        if cx > maxcnt then cx
        else cx + fn(y)
      | Const _ -> 1
      | Var _ -> 1
      | Abs(_,y) -> 1 + fn(y)
    in fn(t) > maxcnt

  (** For tactics **)

  (* # records to keep in tac_locs *)
  (* The five default buckets share this number, so each keeps 4 records
     (quotas 4,4,4,4,4). The help text and output of run-with-sampling.sh and
     the docs state that default; update them when this value changes. *)
  let max_num_records = 20

  let is_goal_too_large (a_goal:goal): bool =
    (* Max. assumptions that a goal may have; otherwise drop it *)
    let max_assumptions = 150 in
    let asl,w = a_goal in
    List.length asl > max_assumptions ||
    is_term_too_large w

  type tac_record_interestingness = {
    (* The length of string_of concl of goal_before. Shorter is better *)
    input_concl_str_len: int
  }
  let mk_tac_record_interestingness (tr:tac_record) =
    {
      input_concl_str_len = String.length (string_of_term (snd tr.goal_before))
    }

  let compare_tac_interestingness
      (r1:tac_record_interestingness) r2: int =
    (* Just compare the size of the input conclusion *)
    compare r1.input_concl_str_len r2.input_concl_str_len


  (** For conversions **)

  type conv_record_interestingness = {
    (* The length of string_of_term of input. Shorter is better *)
    input_term_str_len: int
  }
  let mk_conv_record_interestingness (cr:conv_record) =
    {
      input_term_str_len = String.length (string_of_term cr.input)
    }

  let all_conv_records_interesting
      (tr: (conv_record * record_args * conv_record_interestingness) list): bool =
    let interesting_term_strlen = 50 in
    List.for_all (fun (_,_,i) -> i.input_term_str_len < interesting_term_strlen)
      tr

  let compare_conv_interestingness
      (r1:conv_record_interestingness) r2: int =
    (* Just compare the size of the input terms *)
    compare r1.input_term_str_len r2.input_term_str_len


  (***************************************************************************)
  (*                                  Full record                            *)
  (***************************************************************************)

  let tac_logs
    :(string,
        (tac_record * record_args Lazy.t * tac_record_interestingness) list)
      Hashtbl.t =
    (* Tactic arguments stay lazy while records compete for retention.
       Conversion records remain eager below. *)
    Hashtbl.create 128
  let conv_logs
    :(string,
        (conv_record * record_args * conv_record_interestingness) list)
      Hashtbl.t =
    Hashtbl.create 128

  (***************************************************************************)
  (*                        Runtime tactic sampling                          *)
  (***************************************************************************)

  type sampling_config = {
    output_dir: string option;
    bucket_quotas: int array;
    backfill: bool;
  }

  (* Five buckets by default, sharing max_num_records as evenly as they can. *)
  let default_bucket_quotas = Array.init 5 (fun i ->
    max_num_records / 5 + if i < max_num_records mod 5 then 1 else 0)

  (* Each run keeps its own copy of the quota array, so a caller that reuses
     the array it passed in cannot change a run that has already started. *)
  let default_sampling_config = {
    output_dir = None;
    bucket_quotas = Array.copy default_bucket_quotas;
    backfill = true;
  }
  let sampling_config = ref {default_sampling_config with
    bucket_quotas = Array.copy default_bucket_quotas}
  let sampling_config_sealed = ref false

  (* The dump never replaces anything. Checking when the directory is chosen
     makes a collision fail before the proof runs, not after it. *)
  let check_output_absent dir ~summary =
    if Sys.file_exists dir then
      invalid_arg ("Trace output directory already exists: " ^ dir);
    if summary && Sys.file_exists (dir ^ ".sampling.json") then
      invalid_arg ("Sampling summary already exists: " ^ dir ^ ".sampling.json")

  let configure_sampling config =
    if !sampling_config_sealed then
      invalid_arg "Trace sampling configuration is sealed after first collection or dump";
    if not (List.mem (Array.length config.bucket_quotas) [1; 5]) ||
       Array.exists (fun quota -> quota < 0) config.bucket_quotas then
      invalid_arg "Trace bucket quotas require 1 or 5 nonnegative capacities";
    if Array.fold_left (+) 0 config.bucket_quotas < 1 then
      invalid_arg "Trace bucket quotas must have a positive total";
    (match config.output_dir with
     | None -> ()
     | Some dir ->
       if Filename.is_relative dir then
         invalid_arg "Trace output directory must be an absolute path";
       let basename = Filename.basename dir in
       if basename = "" || basename = "." || basename = ".." ||
          dir.[String.length dir - 1] = '/' then
         invalid_arg "Trace output directory must end in a directory name";
       (* The summary sits next to the directory and is compared by path, so
          the path must already be in normal form. *)
       if List.exists (fun c -> c = "" || c = "." || c = "..")
            (List.tl (String.split_on_char '/' dir)) then
         invalid_arg "Trace output directory must not contain empty, '.' or '..' components";
       let parent = Filename.dirname dir in
       if not (Sys.file_exists parent) || not (Sys.is_directory parent) then
         invalid_arg "Parent of the trace output directory must be an existing directory";
       check_output_absent dir ~summary:true);
    sampling_config := {config with bucket_quotas = Array.copy config.bucket_quotas}

  let get_sampling_config () =
    sampling_config_sealed := true;
    !sampling_config

  (* Set by exptrace_set_default_dir: where the traces go unless the sampling
     configuration names a directory. *)
  let default_output_dir : string option ref = ref None

  (* The one place the traces are written. *)
  let effective_output_dir config =
    match config.output_dir, !default_output_dir with
    | Some dir, _ | None, Some dir -> dir
    | None, None ->
      invalid_arg "No trace output directory: set output_dir in the sampling \
                   configuration, or call exptrace_set_default_dir"

  let bucket_names config =
    if Array.length config.bucket_quotas = 1 then [|"0+"|]
    else [|"0"; "1"; "2"; "3"; "4+"|]

  let bucket_index config n =
    min n (Array.length config.bucket_quotas - 1)

  type sampled_record = {
    trace: tac_record * record_args Lazy.t * tac_record_interestingness;
    arrival: int;
  }
  type sampling_bucket = {
    mutable eligible_seen: int;
    slots: sampled_record option array;
  }
  type tactic_sampling_stats = {
    mutable filtered: int;
    mutable arrivals: int;
    buckets: sampling_bucket array;
    overflow_buckets: sampling_bucket array;
  }
  let sampling_stats : (string, tactic_sampling_stats) Hashtbl.t =
    Hashtbl.create 128

  let total_capacity config =
    Array.fold_left (+) 0 config.bucket_quotas

  let get_sampling_stats config tactic_name =
    match Hashtbl.find_opt sampling_stats tactic_name with
    | Some stats -> stats
    | None ->
      let capacity = total_capacity config in
      let make_bucket quota = {
        eligible_seen = 0; slots = Array.make quota None;
      } in
      let stats = {
        filtered = 0;
        arrivals = 0;
        buckets = Array.map make_bucket config.bucket_quotas;
        (* A bucket that may borrow places needs room for every record it
           gives up, so an overflow bucket holds the whole capacity. *)
        overflow_buckets = Array.map (fun quota ->
          make_bucket (if config.backfill && quota > 0 then capacity else 0))
          config.bucket_quotas;
      } in
      Hashtbl.add sampling_stats tactic_name stats;
      stats

  let make_sampled_record re re_arg_gen arrival = {
    trace = (re, lazy (re_arg_gen ()), mk_tac_record_interestingness re);
    arrival;
  }

  let compare_sampled a b =
    let _,_,ai = a.trace and _,_,bi = b.trace in
    let by_length = compare ai.input_concl_str_len bi.input_concl_str_len in
    if by_length <> 0 then by_length else compare a.arrival b.arrival

  (* Keep the candidate if the bucket has room or if it beats the bucket's
     worst record, and return the record that lost its place, if any. *)
  let offer_record bucket candidate =
    let empty = ref None and worst = ref None in
    Array.iteri (fun i slot -> match slot with
      | None -> if !empty = None then empty := Some i
      | Some old ->
        (match !worst with
         | None -> worst := Some (i,old)
         | Some (_,current) ->
           if compare_sampled old current > 0 then worst := Some (i,old)))
      bucket.slots;
    match !empty, !worst with
    | Some i, _ -> bucket.slots.(i) <- Some candidate; None
    | None, Some (i,old) when compare_sampled candidate old < 0 ->
      bucket.slots.(i) <- Some candidate; Some old
    | _ -> Some candidate

  let add_sampled_record config stats bucket re re_arg_gen =
    if Array.length bucket.slots > 0 then begin
      let candidate =
        make_sampled_record re re_arg_gen stats.arrivals in
      match offer_record bucket candidate with
      | Some displaced when config.backfill ->
        ignore (offer_record
          stats.overflow_buckets.(bucket_index config re.num_subgoals) displaced)
      | _ -> ()
    end

  (* How many records each bucket keeps at dump. A bucket first takes up to
     its own quota. With borrowing, places that no bucket can fill go round
     robin, in bucket order, to the buckets that have more records left. A
     zero quota disables its bucket, so it neither keeps nor borrows. *)
  let effective_bucket_capacities config stats =
    let targets = Array.mapi (fun i quota ->
      min quota stats.buckets.(i).eligible_seen) config.bucket_quotas in
    if config.backfill then begin
      let remaining = ref
        (total_capacity config - Array.fold_left (+) 0 targets) in
      let rec allocate () =
        let active = ref [] in
        Array.iteri (fun i quota ->
          if quota > 0 && targets.(i) < stats.buckets.(i).eligible_seen then
            active := i :: !active) config.bucket_quotas;
        let active = List.rev !active in
        if !remaining > 0 && active <> [] then begin
          (* Give every active bucket the same number of places while that
             many are still available everywhere, then hand out single ones. *)
          let rounds = List.fold_left (fun count i ->
            min count (min !remaining
              (stats.buckets.(i).eligible_seen - targets.(i))))
            (!remaining / List.length active) active in
          List.iter (fun i ->
            let amount = if rounds > 0 then rounds else min 1 !remaining in
            targets.(i) <- targets.(i) + amount;
            remaining := !remaining - amount) active;
          allocate ()
        end in
      allocate ()
    end;
    targets

  let sampled_tac_logs config =
    let result = Hashtbl.create 128 in
    Hashtbl.iter (fun name stats ->
      let targets = effective_bucket_capacities config stats in
      let kept = Array.to_list (Array.mapi (fun i target ->
        let primary = Array.to_list stats.buckets.(i).slots
          |> List.filter_map (fun x -> x) in
        let needed = target - List.length primary in
        let extra = if needed <= 0 then [] else
          Array.to_list stats.overflow_buckets.(i).slots
          |> List.filter_map (fun x -> x)
          |> List.sort compare_sampled in
        let rec take n = function
          | _ when n <= 0 -> []
          | [] -> failwith "Trace sampling: a bucket borrowed more places than it has records"
          | first :: rest -> first :: take (n - 1) rest in
        primary @ take needed extra) targets)
        |> List.flatten in
      (* Records are written shortest first, and newest first among records
         of equal length. *)
      let newest_first a b =
        let _,_,ai = a.trace and _,_,bi = b.trace in
        let by_length = compare ai.input_concl_str_len bi.input_concl_str_len in
        if by_length <> 0 then by_length else compare b.arrival a.arrival in
      let records = List.map (fun candidate -> candidate.trace)
        (List.sort newest_first kept) in
      if records <> [] then Hashtbl.add result name records) sampling_stats;
    result

  (* The sampling summary uses JSON escaping, including all ASCII control
     characters. *)
  let json_string value =
    let buffer = Buffer.create (String.length value + 2) in
    Buffer.add_char buffer '"';
    String.iter (fun c -> match c with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | c when Char.code c < 32 ->
        Buffer.add_string buffer (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buffer c) value;
    Buffer.add_char buffer '"';
    Buffer.contents buffer

  let write_sampling_summary oc config output_dir tac_logs =
    let names = bucket_names config in
    Printf.fprintf oc
      "{\n  \"backfill\": %s,\n  \"total_capacity\": %d,\n"
      (string_of_bool config.backfill) (total_capacity config);
    Printf.fprintf oc "  \"bucket_names\": [%s],\n  \"bucket_capacities\": %s,\n"
      (String.concat ", " (Array.to_list (Array.map json_string names)))
      ("[" ^ String.concat ", "
         (Array.to_list (Array.map string_of_int config.bucket_quotas)) ^ "]");
    Printf.fprintf oc
      "  \"output_dir\": %s,\n  \"tactics\": {"
      (json_string output_dir);
    let tactics = List.sort compare
      (Hashtbl.fold (fun name _ names -> name :: names) sampling_stats []) in
    List.iteri (fun index name ->
      let stats = Hashtbl.find sampling_stats name in
      let retained = Array.make (Array.length names) 0 in
      (match Hashtbl.find_opt tac_logs name with
       | None -> ()
       | Some records -> List.iter (fun (record,_,_) ->
           let i = bucket_index config record.num_subgoals in
           retained.(i) <- retained.(i) + 1) records);
      Printf.fprintf oc "%s\n    %s: {\"filtered\": %d, "
        (if index = 0 then "" else ",") (json_string name) stats.filtered;
      if config.backfill then
        Printf.fprintf oc "\"effective_bucket_capacities\": [%s], "
          (String.concat ", " (Array.to_list (Array.map string_of_int
            (effective_bucket_capacities config stats))));
      Printf.fprintf oc "\"buckets\": [";
      Array.iteri (fun i bucket ->
        Printf.fprintf oc
          "%s{\"name\": %s, \"eligible_seen\": %d, \"retained\": %d}"
          (if i = 0 then "" else ", ") (json_string names.(i))
          bucket.eligible_seen retained.(i)) stats.buckets;
      Printf.fprintf oc "]}") tactics;
    Printf.fprintf oc "\n  }\n}\n"


end;;


(* modify-proof.sh adds a call to this before the proof, with the directory it
   was given. It is the output directory unless the sampling configuration
   names another. A run has one output directory: the default may be set again
   with the same value, but not changed. *)
let exptrace_set_default_dir (dir_path:string): unit =
  match !ExportTrace.default_output_dir with
  | Some dir when dir = dir_path -> ()
  | Some dir ->
    invalid_arg ("Default trace output directory is already set to " ^ dir)
  | None ->
    if (!ExportTrace.sampling_config).output_dir = None then
      ExportTrace.check_output_absent dir_path ~summary:false;
    ExportTrace.default_output_dir := Some dir_path;;

let exptrace_add_tac (tactic_name:string)
        (re:ExportTrace.tac_record)
        (re_arg_gen:unit -> ExportTrace.record_args)=
  let config = ExportTrace.get_sampling_config () in
  let stats = ExportTrace.get_sampling_stats config tactic_name in
  if ExportTrace.is_goal_too_large re.goal_before ||
    List.exists ExportTrace.is_goal_too_large re.goals_after
  then stats.filtered <- stats.filtered + 1
  else begin
    let bucket =
      stats.buckets.(ExportTrace.bucket_index config re.num_subgoals) in
    bucket.eligible_seen <- bucket.eligible_seen + 1;
    stats.arrivals <- stats.arrivals + 1;
    ExportTrace.add_sampled_record config stats bucket re re_arg_gen
  end;;

let exptrace_add_conv (conv_name:string)
        (re:ExportTrace.conv_record)
        (re_arg_gen:unit -> ExportTrace.record_args) =
  (* Conversions are retained eagerly, but collecting one still seals the
     sampling configuration so that a later call cannot change this run. *)
  ignore (ExportTrace.get_sampling_config ());
  (* If the input term is too large, skip this *)
  if ExportTrace.is_term_too_large re.input then () else
  (* If the result is 't = t', ignore this *)
  if let c = concl re.output in is_eq c && lhs c = rhs c
  then () (* not interesting! *) else

  let logs = ExportTrace.conv_logs in
  (* Lazily calculate interestingness of this tac_record 're'. *)
  let mk_i () = ExportTrace.mk_conv_record_interestingness re in

  let mk_full_rec() = (re, re_arg_gen(), mk_i()) in

  match Hashtbl.find_opt logs conv_name with
  | None ->
    Hashtbl.add logs conv_name [mk_full_rec()]
  | Some records ->
    if List.length records < ExportTrace.max_num_records then
      Hashtbl.replace logs conv_name (mk_full_rec()::records)
    else if ExportTrace.all_conv_records_interesting records then
      () (* no need to update records *)
    else begin
      assert (List.length records = ExportTrace.max_num_records);
      let new_records = List.sort
          (fun (_,_,i1) (_,_,i2) -> ExportTrace.compare_conv_interestingness i1 i2)
          (mk_full_rec()::records) in
      let new_records = rev (tl (rev new_records)) in
      Hashtbl.replace logs conv_name new_records
    end;;

(* The dump is an explicit call that modify-proof.sh adds at the end of the
   proof, not an at_exit handler. A proof that fails raises before reaching it,
   so a failed proof writes no traces and no sampling summary. *)
let exptrace_dump (): unit =
  let config = ExportTrace.get_sampling_config () in
  let dir_path = ExportTrace.effective_output_dir config in
  ExportTrace.check_output_absent dir_path ~summary:(config.output_dir <> None);
  let tac_logs = ExportTrace.sampled_tac_logs config in
  let tac_rec_comp (_,_,i1) (_,_,i2) = ExportTrace.compare_tac_interestingness i1 i2 in
  let conv_logs = ExportTrace.conv_logs in
  let conv_rec_comp (_,_,i1) (_,_,i2) = ExportTrace.compare_conv_interestingness i1 i2 in

  (* Reserve the sampling summary exclusively before creating the trace
     directory. Neither an existing directory nor an existing summary may be
     replaced. *)
  let summary_channel = match config.output_dir with
    | None -> None
    | Some _ -> Some (open_out_gen [Open_wronly; Open_creat; Open_excl; Open_text]
        0o666 (dir_path ^ ".sampling.json")) in
  try
  Sys.mkdir dir_path 0o777;
  let string_of_asm_list l =
    (List.map (fun th -> "\"" ^ String.escaped (string_of_term (concl (snd th))) ^ "\"") l) in

  Hashtbl.iter (fun tac recs ->
      let recs = List.sort tac_rec_comp recs in
      let path = dir_path ^ "/" ^ tac ^ ".json" in
      let oc = open_out path in

      Printf.fprintf oc "[\n";
      List.iteri (fun i ((r:ExportTrace.tac_record),r_args_lazy,_) ->
          (* Render arguments only after this record has survived retention. *)
          let r_args:ExportTrace.record_args = Lazy.force r_args_lazy in
          Printf.fprintf oc "  {\n";
          Printf.fprintf oc "    \"tactic\":\"%s\",\n" tac;
          Printf.fprintf oc "    \"definition_line_number\": {\n";
          Printf.fprintf oc "       \"file_path\": \"%s\",\n"
            (String.escaped (fst r.definition_line_number));
          Printf.fprintf oc "       \"line\": %d\n" (snd r.definition_line_number);
          Printf.fprintf oc "    },\n";
          Printf.fprintf oc "    \"user_line_number\": {\n";
          Printf.fprintf oc "       \"file_path\": \"%s\",\n"
            (String.escaped (fst r.user_line_number));
          Printf.fprintf oc "       \"line\": %d\n" (snd r.user_line_number);
          Printf.fprintf oc "    },\n";
          Printf.fprintf oc "    \"arg_names\": [%s],\n"
            (String.concat ", " (List.map (fun s -> "\"" ^ s ^ "\"") r_args.names));
          Printf.fprintf oc "    \"arg_types\": [%s],\n"
            (String.concat ", " (List.map (fun s -> "\"" ^ s ^ "\"") r_args.types));
          Printf.fprintf oc "    \"arg_values\": [%s],\n"
            (String.concat ", " (List.map (fun s -> "\"" ^ (String.escaped s) ^ "\"") r_args.values));
          Printf.fprintf oc "    \"arg_exprs\": [%s],\n"
            (String.concat ", " (List.map (fun s -> "\"" ^ (String.escaped s) ^ "\"") r_args.exprs));
          Printf.fprintf oc "    \"goal_before\": \"%s\",\n"
            (String.escaped (Format.asprintf "%a" pp_print_goal r.goal_before));
          Printf.fprintf oc "    \"goals_after\": [%s],\n"
            (String.concat ", " (List.map (fun g ->
              "{\"goal\": \"" ^
              String.escaped (Format.asprintf "%a" pp_print_goal g) ^
              "\", \"added_assumptions\": [" ^
              String.concat ","
                (string_of_asm_list (subtract (fst g) (fst r.goal_before))) ^
              "], \"removed_assumptions\": [" ^
              String.concat ","
                (string_of_asm_list (subtract (fst r.goal_before) (fst g))) ^
              "]}")
            r.goals_after));
          Printf.fprintf oc "    \"num_subgoals\": %d\n" r.num_subgoals;
          Printf.fprintf oc "  }%s\n" (if i + 1 = List.length recs then "" else ","))
        recs;
      Printf.fprintf oc "]\n";
      Printf.printf "Dumped to %s\n" path;
      close_out oc)
    tac_logs;

  Hashtbl.iter (fun conv recs ->
      let recs = List.sort conv_rec_comp recs in
      let path = dir_path ^ "/" ^ conv ^ ".json" in
      let oc = open_out path in

      Printf.fprintf oc "[\n";
      List.iteri (fun i ((r:ExportTrace.conv_record),(r_args:ExportTrace.record_args),_) ->
          Printf.fprintf oc "  {\n";
          Printf.fprintf oc "    \"conv\":\"%s\",\n" conv;
          Printf.fprintf oc "    \"definition_line_number\": {\n";
          Printf.fprintf oc "       \"file_path\": \"%s\",\n"
            (String.escaped (fst r.definition_line_number));
          Printf.fprintf oc "       \"line\": %d\n" (snd r.definition_line_number);
          Printf.fprintf oc "    },\n";
          Printf.fprintf oc "    \"user_line_number\": {\n";
          Printf.fprintf oc "       \"file_path\": \"%s\",\n"
            (String.escaped (fst r.user_line_number));
          Printf.fprintf oc "       \"line\": %d\n" (snd r.user_line_number);
          Printf.fprintf oc "    },\n";
          Printf.fprintf oc "    \"arg_names\": [%s],\n"
            (String.concat ", " (List.map (fun s -> "\"" ^ s ^ "\"") r_args.names));
          Printf.fprintf oc "    \"arg_types\": [%s],\n"
            (String.concat ", " (List.map (fun s -> "\"" ^ s ^ "\"") r_args.types));
          Printf.fprintf oc "    \"arg_values\": [%s],\n"
            (String.concat ", " (List.map (fun s -> "\"" ^ (String.escaped s) ^ "\"") r_args.values));
          Printf.fprintf oc "    \"arg_exprs\": [%s],\n"
            (String.concat ", " (List.map (fun s -> "\"" ^ (String.escaped s) ^ "\"") r_args.exprs));
          Printf.fprintf oc "    \"output\": \"%s\"\n"
            (String.escaped (Format.asprintf "%a" pp_print_thm r.output));
          Printf.fprintf oc "  }%s\n" (if i + 1 = List.length recs then "" else ","))
        recs;
      Printf.fprintf oc "]\n";
      Printf.printf "Dumped to %s\n" path;
      close_out oc)
    conv_logs;
  (match summary_channel with
   | None -> ()
   | Some oc ->
     ExportTrace.write_sampling_summary oc config dir_path tac_logs;
     close_out oc)
  with exn ->
    (* The summary was created by this dump, so an incomplete one is removed
       rather than left to block the next run. *)
    (match summary_channel with
     | None -> ()
     | Some oc ->
       close_out_noerr oc;
       (try Sys.remove (dir_path ^ ".sampling.json") with Sys_error _ -> ()));
    raise exn;;

(* a helper function *)
let rec to_n_elems (r:string list) n:string list =
  if n = 0 then []
  else match r with
  | h::t -> h::(to_n_elems t (n-1))
  | [] -> replicate "(unknown)" n;;


set_jrh_lexer;;
