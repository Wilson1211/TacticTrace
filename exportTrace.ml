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
    bucket_quotas: int array;
    selection_mode: string;
    backfill: bool;
  }

  let default_bucket_quotas = Array.init 3 (fun i ->
    max_num_records / 3 + if i < max_num_records mod 3 then 1 else 0)

  (* Sampling is always enabled. Callers may override these settings before
     collecting a record. Copy quota arrays to keep a live run immutable. *)
  let default_sampling_config = {
    policy = "stratified-reservoir"; seed = 0L; output_root = None;
    bucket_quotas = Array.copy default_bucket_quotas;
    selection_mode = "deterministic"; backfill = false;
  }
  let sampling_config = ref {default_sampling_config with
    bucket_quotas = Array.copy default_bucket_quotas}
  let sampling_config_sealed = ref false

  let configure_sampling config =
    if !sampling_config_sealed then
      invalid_arg "Trace sampling configuration is sealed after first collection or dump";
    if config.policy <> "stratified-reservoir" then
      invalid_arg "Trace sampling policy must be stratified-reservoir";
    if config.selection_mode <> "deterministic" &&
       config.selection_mode <> "random" then
      invalid_arg "Trace selection mode must be deterministic or random";
    if config.seed < 0L || config.seed > 2147483647L then
      invalid_arg "Trace sampling seed must be in 0..2147483647";
    if not (List.mem (Array.length config.bucket_quotas) [1; 3; 5]) ||
       Array.exists (fun n -> n < 0 || n > 2147483647)
         config.bucket_quotas then
      invalid_arg "Trace bucket quotas require 1, 3, or 5 nonnegative capacities";
    let total = Array.fold_left
      (fun n quota -> Int64.add n (Int64.of_int quota))
      0L config.bucket_quotas in
    if total < 1L || total > 2147483647L then
      invalid_arg "Trace bucket quota sum must be in 1..2147483647";
    (match config.output_root with
     | None -> ()
     | Some root ->
       if Filename.is_relative root || not (Sys.file_exists root) ||
          not (Sys.is_directory root) then
         invalid_arg "Trace output root must be an absolute existing directory");
    sampling_config := {config with bucket_quotas = Array.copy config.bucket_quotas}

  let get_sampling_config () =
    sampling_config_sealed := true;
    !sampling_config

  let bucket_names config =
    if Array.length config.bucket_quotas = 1 then [|"0+"|]
    else if Array.length config.bucket_quotas = 3 then [|"0"; "1"; "2+"|]
    else [|"0"; "1"; "2"; "3"; "4+"|]

  let bucket_index config n =
    min n (Array.length config.bucket_quotas - 1)

  type sampled_record = {
    trace: tac_record * record_args Lazy.t * tac_record_interestingness;
    arrival: int64;
  }
  type sampling_bucket = {
    mutable eligible_seen: int64;
    mutable rng: int64;
    slots: sampled_record option array;
  }
  type tactic_sampling_stats = {
    mutable filtered: int64;
    buckets: sampling_bucket array;
    overflow_buckets: sampling_bucket array;
  }
  let sampling_stats : (string, tactic_sampling_stats) Hashtbl.t =
    Hashtbl.create 128

  (* FNV-1a and SplitMix64 give each tactic and group a private random stream. *)
  let bucket_seed seed tactic_name bucket =
    let hash = ref 0xcbf29ce484222325L in
    String.iter (fun c ->
      hash := Int64.mul (Int64.logxor !hash (Int64.of_int (Char.code c)))
        0x100000001b3L) tactic_name;
    Int64.logxor !hash (Int64.logxor (Int64.shift_left seed 2)
      (Int64.of_int bucket))

  let total_capacity config =
    Array.fold_left (+) 0 config.bucket_quotas

  let get_sampling_stats config tactic_name =
    match Hashtbl.find_opt sampling_stats tactic_name with
    | Some stats -> stats
    | None ->
      let capacity = total_capacity config in
      let make_bucket i quota = {
        eligible_seen = 0L; rng = bucket_seed config.seed tactic_name i;
        slots = Array.make quota None;
      } in
      let stats = {
        filtered = 0L;
        (* Stream 3 stays reserved for the separate s2n failure sampler. *)
        buckets = Array.mapi (fun i quota ->
          make_bucket (if i < 3 then i else i + 1) quota)
          config.bucket_quotas;
        overflow_buckets = Array.mapi (fun i quota ->
          make_bucket (8 + i)
            (if config.backfill && quota > 0 then capacity else 0))
          config.bucket_quotas;
      } in
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
    let limit = Int64.sub Int64.max_int (Int64.rem Int64.max_int bound) in
    let rec draw () =
      let value = next_random bucket in
      if value >= limit then draw () else Int64.rem value bound in
    draw ()

  let increment_count count =
    if count = Int64.max_int then failwith "Trace sampling counter overflow";
    Int64.succ count

  let make_sampled_record re re_arg_gen arrival = {
    trace = (re, lazy (re_arg_gen ()), mk_tac_record_interestingness re);
    arrival;
  }

  let compare_sampled a b =
    let _,_,ai = a.trace and _,_,bi = b.trace in
    let by_length = compare ai.input_concl_str_len bi.input_concl_str_len in
    if by_length <> 0 then by_length else compare a.arrival b.arrival

  (* Return the rejected or displaced record. Earlier equal-length records
     win, including when a previous primary winner enters overflow later. *)
  let offer_deterministic bucket candidate =
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
    | Some i, _ -> bucket.slots.(i) <- Some candidate; (true,None)
    | None, Some (i,old) when compare_sampled candidate old < 0 ->
      bucket.slots.(i) <- Some candidate; (true,Some old)
    | _ -> (false,Some candidate)

  let reservoir_slot bucket =
    let capacity = Array.length bucket.slots in
    let slot =
      if bucket.eligible_seen <= Int64.of_int capacity then
        Int64.pred bucket.eligible_seen
      else random_below bucket bucket.eligible_seen in
    if slot < Int64.of_int capacity then Some (Int64.to_int slot) else None

  let offer_overflow config bucket candidate =
    if Array.length bucket.slots > 0 then begin
      bucket.eligible_seen <- increment_count bucket.eligible_seen;
      if config.selection_mode = "deterministic" then
        ignore (offer_deterministic bucket candidate)
      else match reservoir_slot bucket with
        | None -> ()
        | Some i -> bucket.slots.(i) <- Some candidate
    end

  let refresh_tac_logs tactic_name stats =
    let records = Array.fold_left (fun records bucket ->
      Array.fold_left (fun records slot -> match slot with
        | None -> records | Some candidate -> candidate.trace :: records)
        records bucket.slots) [] stats.buckets in
    if records <> [] then Hashtbl.replace tac_logs tactic_name records

  let add_sampled_record config tactic_name stats bucket re re_arg_gen =
    if Array.length bucket.slots = 0 then ()
    else if config.selection_mode = "deterministic" then begin
      let candidate =
        make_sampled_record re re_arg_gen bucket.eligible_seen in
      let accepted,rejected = offer_deterministic bucket candidate in
      (match rejected with
       | Some value when config.backfill ->
         offer_overflow config
           stats.overflow_buckets.(bucket_index config re.num_subgoals) value
       | _ -> ());
      if accepted then refresh_tac_logs tactic_name stats
    end else begin
      let slot = reservoir_slot bucket in
      if slot <> None || config.backfill then begin
        let candidate =
          make_sampled_record re re_arg_gen bucket.eligible_seen in
        let rejected = match slot with
          | None -> Some candidate
          | Some i ->
            let previous = bucket.slots.(i) in
            bucket.slots.(i) <- Some candidate;
            previous in
        (match rejected with
         | Some value when config.backfill ->
           offer_overflow config
             stats.overflow_buckets.(bucket_index config re.num_subgoals) value
         | _ -> ());
        if slot <> None then refresh_tac_logs tactic_name stats
      end
    end

  (* An unused quota goes to eligible groups with excess candidates, one
     place per group per round. A zero quota disables that group entirely. *)
  let effective_bucket_capacities config stats =
    let targets = Array.mapi (fun i quota ->
      Int64.to_int (min (Int64.of_int quota)
        stats.buckets.(i).eligible_seen)) config.bucket_quotas in
    if config.backfill then begin
      let remaining = ref
        (total_capacity config - Array.fold_left (+) 0 targets) in
      let rec allocate () =
        let active = ref [] in
        Array.iteri (fun i quota ->
          if quota > 0 &&
             Int64.of_int targets.(i) < stats.buckets.(i).eligible_seen then
            active := i :: !active) config.bucket_quotas;
        let active = List.rev !active in
        if !remaining > 0 && active <> [] then begin
          let rounds = List.fold_left (fun count i ->
            min count (Int64.to_int (min (Int64.of_int !remaining)
              (Int64.sub stats.buckets.(i).eligible_seen
                (Int64.of_int targets.(i))))))
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
    if config.selection_mode = "deterministic" then begin
      let result = Hashtbl.create 128 in
      Hashtbl.iter (fun name stats ->
        let targets = effective_bucket_capacities config stats in
        let records = Array.to_list (Array.mapi (fun i target ->
          let primary = Array.to_list stats.buckets.(i).slots
            |> List.filter_map (fun x -> x)
            |> List.sort compare_sampled in
          let needed = target - List.length primary in
          let extra = if needed <= 0 then [] else
            Array.to_list stats.overflow_buckets.(i).slots
            |> List.filter_map (fun x -> x)
            |> List.sort compare_sampled in
          let rec take n = function
            | _ when n <= 0 -> []
            | [] -> failwith "Trace sampling overflow is missing backfill candidates"
            | first :: rest -> first :: take (n - 1) rest in
          List.map (fun candidate -> candidate.trace)
            (primary @ take needed extra)) targets)
          |> List.flatten in
        if records <> [] then Hashtbl.add result name records) sampling_stats;
      result
    end else if not config.backfill then tac_logs
    else begin
      let result = Hashtbl.copy tac_logs in
      Hashtbl.iter (fun name stats ->
        let targets = effective_bucket_capacities config stats in
        let extras = ref [] in
        Array.iteri (fun i target ->
          let primary = Int64.to_int
            (min stats.buckets.(i).eligible_seen
              (Int64.of_int config.bucket_quotas.(i))) in
          let needed = target - primary in
          if needed > 0 then begin
            let candidates = Array.to_list stats.overflow_buckets.(i).slots
              |> List.filter_map (fun x -> x) |> Array.of_list in
            if config.selection_mode = "deterministic" then
              Array.sort compare_sampled candidates
            else begin
              let rng = {
                eligible_seen = 0L;
                rng = bucket_seed config.seed name (32 + i);
                slots = [||];
              } in
              for j = Array.length candidates - 1 downto 1 do
                let k = Int64.to_int (random_below rng (Int64.of_int (j + 1))) in
                let value = candidates.(j) in
                candidates.(j) <- candidates.(k);
                candidates.(k) <- value
              done
            end;
            if needed > Array.length candidates then
              failwith "Trace sampling overflow is missing backfill candidates";
            for j = 0 to needed - 1 do
              extras := candidates.(j).trace :: !extras
            done
          end) targets;
        if !extras <> [] then begin
          let primary = match Hashtbl.find_opt tac_logs name with
            | None -> [] | Some records -> records in
          Hashtbl.replace result name (primary @ List.rev !extras)
        end) sampling_stats;
      result
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

  let write_sampling_metadata oc config original_path actual_path tac_logs =
    let names = bucket_names config in
    Printf.fprintf oc
      "{\n  \"policy_version\": %d,\n  \"policy\": %s,\n  \"selection_mode\": %s,\n  \"backfill\": %s,\n  \"seed\": %Ld,\n  \"total_capacity\": %d,\n"
      2
      (json_string config.policy) (json_string config.selection_mode)
      (string_of_bool config.backfill) config.seed
      (total_capacity config);
    Printf.fprintf oc "  \"bucket_names\": [%s],\n  \"bucket_capacities\": %s,\n"
      (String.concat ", " (Array.to_list (Array.map json_string names)))
      ("[" ^ String.concat ", "
         (Array.to_list (Array.map string_of_int config.bucket_quotas)) ^ "]");
    Printf.fprintf oc
      "  \"original_output_path\": %s,\n  \"actual_output_path\": %s,\n  \"tactics\": {"
      (json_string original_path) (json_string actual_path);
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
      Printf.fprintf oc "%s\n    %s: {\"filtered\": %Ld, "
        (if index = 0 then "" else ",") (json_string name) stats.filtered;
      if config.backfill then
        Printf.fprintf oc "\"effective_bucket_capacities\": [%s], "
          (String.concat ", " (Array.to_list (Array.map string_of_int
            (effective_bucket_capacities config stats))));
      Printf.fprintf oc "\"buckets\": [";
      Array.iteri (fun i bucket ->
        Printf.fprintf oc
          "%s{\"name\": %s, \"eligible_seen\": %Ld, \"retained\": %d}"
          (if i = 0 then "" else ", ") (json_string names.(i))
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
  let bucket = stats.buckets.(ExportTrace.bucket_index config re.num_subgoals) in
  bucket.eligible_seen <- ExportTrace.increment_count bucket.eligible_seen;
  ExportTrace.add_sampled_record config tactic_name stats bucket re re_arg_gen
  end;;

let exptrace_add_conv (conv_name:string)
        (re:ExportTrace.conv_record)
        (re_arg_gen:unit -> ExportTrace.record_args) =
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
  let tac_logs = ExportTrace.sampled_tac_logs config in
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
     ExportTrace.write_sampling_metadata oc config original_path dir_path tac_logs;
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
