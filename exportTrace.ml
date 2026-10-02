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

  let all_tac_records_interesting
      (tr: (tac_record * record_args Lazy.t * tac_record_interestingness) list): bool =
    let interesting_concl_strlen = 100 in
    List.for_all (fun (_,_,i) -> i.input_concl_str_len < interesting_concl_strlen)
      tr

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
  (*                    Runtime tactic sampling policy                       *)
  (***************************************************************************)

  type sampling_config = {
    policy: string;
    seed: int64;
    output_root: string option;
  }

  (* Read the environment on the first collection or dump, not when a HOL
     Light checkpoint containing this module is built. *)
  let sampling_config = ref None

  let get_sampling_config () =
    match !sampling_config with
    | Some config -> config
    | None ->
      let policy = match Sys.getenv_opt "TRACE_SAMPLING_POLICY" with
        | None -> "legacy" | Some value -> value in
      if policy <> "legacy" && policy <> "stratified-reservoir" then
        invalid_arg "TRACE_SAMPLING_POLICY must be legacy or stratified-reservoir";
      let seed_text = match Sys.getenv_opt "TRACE_SAMPLING_SEED" with
        | None -> "0" | Some value -> value in
      let valid_decimal =
        String.length seed_text > 0 && String.length seed_text <= 10 &&
        (String.length seed_text = 1 || seed_text.[0] <> '0') &&
        String.for_all (fun c -> c >= '0' && c <= '9') seed_text in
      if not valid_decimal then
        invalid_arg "TRACE_SAMPLING_SEED must be canonical decimal in 0..2147483647";
      let seed = Int64.of_string seed_text in
      if seed > 2147483647L then
        invalid_arg "TRACE_SAMPLING_SEED must be canonical decimal in 0..2147483647";
      let output_root = Sys.getenv_opt "TRACE_SAMPLING_OUTPUT_ROOT" in
      (match output_root with
       | None ->
         if policy <> "legacy" then
           invalid_arg "TRACE_SAMPLING_OUTPUT_ROOT is required for stratified-reservoir"
       | Some root ->
         if Filename.is_relative root || not (Sys.file_exists root) ||
            not (Sys.is_directory root) then
           invalid_arg "TRACE_SAMPLING_OUTPUT_ROOT must be an absolute existing directory");
      let config = {policy; seed; output_root} in
      sampling_config := Some config;
      config

  let bucket_names = [|"0"; "1"; "2+"|]
  let bucket_capacities = Array.init 3 (fun i ->
    max_num_records / 3 + if i < max_num_records mod 3 then 1 else 0)
  let bucket_index n = if n = 0 then 0 else if n = 1 then 1 else 2

  type sampling_bucket = {
    mutable eligible_seen: int64;
    mutable rng: int64;
    slots: (tac_record * record_args Lazy.t * tac_record_interestingness)
      option array;
  }
  type tactic_sampling_stats = {
    mutable filtered: int64;
    buckets: sampling_bucket array;
  }
  let sampling_stats : (string, tactic_sampling_stats) Hashtbl.t =
    Hashtbl.create 128

  (* FNV-1a mixes the tactic's bytes into an explicitly defined seed. Each
     bucket has its own SplitMix64 stream, independent of proof randomness
     and of the order in which other tactics or buckets are encountered. *)
  let bucket_seed seed tactic_name bucket =
    let hash = ref 0xcbf29ce484222325L in
    String.iter (fun c ->
      hash := Int64.mul (Int64.logxor !hash (Int64.of_int (Char.code c)))
        0x100000001b3L) tactic_name;
    Int64.logxor !hash (Int64.logxor (Int64.shift_left seed 2)
      (Int64.of_int bucket))

  let get_sampling_stats config tactic_name =
    match Hashtbl.find_opt sampling_stats tactic_name with
    | Some stats -> stats
    | None ->
      let stats = {filtered = 0L; buckets = Array.mapi (fun i capacity ->
        {eligible_seen = 0L; rng = bucket_seed config.seed tactic_name i;
         slots = Array.make capacity None}) bucket_capacities} in
      Hashtbl.add sampling_stats tactic_name stats;
      stats

  let next_random bucket =
    bucket.rng <- Int64.add bucket.rng 0x9e3779b97f4a7c15L;
    let z = bucket.rng in
    let z = Int64.mul
      (Int64.logxor z (Int64.shift_right_logical z 30)) 0xbf58476d1ce4e5b9L in
    let z = Int64.mul
      (Int64.logxor z (Int64.shift_right_logical z 27)) 0x94d049bb133111ebL in
    Int64.shift_right_logical
      (Int64.logxor z (Int64.shift_right_logical z 31)) 1

  let random_below bucket bound =
    (* Reject the incomplete tail so every result has equal probability. *)
    let limit = Int64.sub Int64.max_int (Int64.rem Int64.max_int bound) in
    let rec draw () =
      let value = next_random bucket in
      if value >= limit then draw () else Int64.rem value bound in
    draw ()

  let increment_count count =
    if count = Int64.max_int then failwith "Trace sampling counter overflow";
    Int64.succ count

  let add_reservoir_record tactic_name stats bucket re re_arg_gen =
    let capacity = Array.length bucket.slots in
    let slot =
      if bucket.eligible_seen <= Int64.of_int capacity then
        Int64.pred bucket.eligible_seen
      else random_below bucket bucket.eligible_seen in
    if slot < Int64.of_int capacity then begin
      (* Selection precedes all pretty printing and argument rendering. *)
      let record = (re, lazy (re_arg_gen ()), mk_tac_record_interestingness re) in
      bucket.slots.(Int64.to_int slot) <- Some record;
      let records = Array.fold_left (fun records b ->
        Array.fold_left (fun records slot -> match slot with
          | None -> records | Some record -> record :: records)
          records b.slots) [] stats.buckets in
      Hashtbl.replace tac_logs tactic_name records
    end

  (* Metadata uses JSON escaping, including all ASCII control characters. *)
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

  let write_sampling_metadata oc config original_path actual_path =
    Printf.fprintf oc
      "{\n  \"policy_version\": 1,\n  \"policy\": %s,\n  \"seed\": %Ld,\n  \"total_capacity\": %d,\n"
      (json_string config.policy) config.seed max_num_records;
    Printf.fprintf oc "  \"bucket_names\": [%s],\n  \"bucket_capacities\": %s,\n"
      (String.concat ", " (Array.to_list (Array.map json_string bucket_names)))
      (if config.policy = "legacy" then "null" else
       "[" ^ String.concat ", "
         (Array.to_list (Array.map string_of_int bucket_capacities)) ^ "]");
    Printf.fprintf oc
      "  \"original_output_path\": %s,\n  \"actual_output_path\": %s,\n  \"tactics\": {"
      (json_string original_path) (json_string actual_path);
    let tactics = List.sort compare
      (Hashtbl.fold (fun name _ names -> name :: names) sampling_stats []) in
    List.iteri (fun index name ->
      let stats = Hashtbl.find sampling_stats name in
      let retained = Array.make 3 0 in
      (match Hashtbl.find_opt tac_logs name with
       | None -> ()
       | Some records -> List.iter (fun (record,_,_) ->
           let i = bucket_index record.num_subgoals in
           retained.(i) <- retained.(i) + 1) records);
      Printf.fprintf oc "%s\n    %s: {\"filtered\": %Ld, \"buckets\": ["
        (if index = 0 then "" else ",") (json_string name) stats.filtered;
      Array.iteri (fun i bucket ->
        Printf.fprintf oc
          "%s{\"name\": %s, \"eligible_seen\": %Ld, \"retained\": %d}"
          (if i = 0 then "" else ", ") (json_string bucket_names.(i))
          bucket.eligible_seen retained.(i)) stats.buckets;
      Printf.fprintf oc "]}") tactics;
    Printf.fprintf oc "\n  }\n}\n"


end;;


let exptrace_add_tac (tactic_name:string)
        (re:ExportTrace.tac_record)
        (re_arg_gen:unit -> ExportTrace.record_args)=
  let config = ExportTrace.get_sampling_config () in
  let stats = ExportTrace.get_sampling_stats config tactic_name in
  if ExportTrace.is_goal_too_large re.goal_before ||
    List.exists ExportTrace.is_goal_too_large re.goals_after
  then stats.filtered <- ExportTrace.increment_count stats.filtered
  else begin
  let bucket = stats.buckets.(ExportTrace.bucket_index re.num_subgoals) in
  bucket.eligible_seen <- ExportTrace.increment_count bucket.eligible_seen;
  if config.policy = "stratified-reservoir" then
    ExportTrace.add_reservoir_record tactic_name stats bucket re re_arg_gen
  else begin

  let logs = ExportTrace.tac_logs in
  (* Lazily calculate interestingness of this tac_record 're'. *)
  let mk_i () = ExportTrace.mk_tac_record_interestingness re in

  (* Do not call re_arg_gen here: the retention logic may discard this record. *)
  let mk_full_rec() = (re, lazy (re_arg_gen()), mk_i()) in

  match Hashtbl.find_opt logs tactic_name with
  | None ->
    Hashtbl.add logs tactic_name [mk_full_rec()]
  | Some records ->
    if List.length records < ExportTrace.max_num_records then
      Hashtbl.replace logs tactic_name (mk_full_rec()::records)
    else if ExportTrace.all_tac_records_interesting records then
      () (* no need to update records *)
    else begin
      assert (List.length records = ExportTrace.max_num_records);
      let new_records = List.sort
          (fun (_,_,i1) (_,_,i2) -> ExportTrace.compare_tac_interestingness i1 i2)
          (mk_full_rec()::records) in
      let new_records = rev (tl (rev new_records)) in
      Hashtbl.replace logs tactic_name new_records
    end
  end
  end;;

let exptrace_add_conv (conv_name:string)
        (re:ExportTrace.conv_record)
        (re_arg_gen:unit -> ExportTrace.record_args) =
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

let exptrace_dump (dir_path:string): unit =
  let config = ExportTrace.get_sampling_config () in
  let original_path = dir_path in
  let dir_path = match config.output_root with
    | None -> dir_path
    | Some root ->
      let basename = Filename.basename dir_path in
      if dir_path = "" || basename = "" || basename = "." || basename = ".." ||
         basename = Filename.dir_sep then
        invalid_arg "Trace output path must have a nonempty directory basename";
      Filename.concat root basename in
  let tac_logs = ExportTrace.tac_logs in
  let tac_rec_comp (_,_,i1) (_,_,i2) = ExportTrace.compare_tac_interestingness i1 i2 in
  let conv_logs = ExportTrace.conv_logs in
  let conv_rec_comp (_,_,i1) (_,_,i2) = ExportTrace.compare_conv_interestingness i1 i2 in

  (* Reserve the sidecar exclusively before creating the trace directory.
     Neither an existing directory nor an existing sidecar may be replaced. *)
  let metadata_channel = match config.output_root with
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
  (match metadata_channel with
   | None -> ()
   | Some oc ->
     ExportTrace.write_sampling_metadata oc config original_path dir_path;
     close_out oc)
  with exn ->
    (match metadata_channel with None -> () | Some oc -> close_out_noerr oc);
    raise exn;;

(* a helper function *)
let rec to_n_elems (r:string list) n:string list =
  if n = 0 then []
  else match r with
  | h::t -> h::(to_n_elems t (n-1))
  | [] -> replicate "(unknown)" n;;


set_jrh_lexer;;
