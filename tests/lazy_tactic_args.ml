(* Verify that tactic argument rendering is deferred until trace dumping. *)

(* Load the collector so inline-load can preserve its source locations. *)
needs "exportTrace.ml";;

unset_jrh_lexer;;
open ExportTrace;;

let test_tactic_name = "__lazy_tactic_args_test__";;

(* This list makes argument rendering observable without doing expensive work. *)
let forced_args = ref [];;

let make_args label () =
  forced_args := label :: !forced_args;
  {
    names = [label];
    types = ["test"];
    values = [label];
    exprs = [label];
  };;

let make_record_from_term n term =
  {
    definition_line_number = ("lazy_tactic_args.ml",n);
    user_line_number = ("lazy_tactic_args.ml",n);
    goal_before = ([],term);
    goals_after = [];
    num_subgoals = 0;
  };;

let test_max_num_records = ExportTrace.max_num_records;;
(* A single group isolates argument laziness from stratification quotas. *)
configure_sampling { default_sampling_config with
  bucket_quotas = [|test_max_num_records|] };;

set_jrh_lexer;;

let make_record n =
  make_record_from_term n (list_mk_conj (replicate `T` (n + 1)));;

let retained_labels =
  List.init test_max_num_records (fun i -> "retained-" ^ string_of_int i);;

(* Reuse one fixed goal so the fixture stays small if the record limit grows. *)
let retained_record = make_record 50;;

List.iteri
  (fun _ label ->
    exptrace_add_tac test_tactic_name retained_record (make_args label))
  retained_labels;;

(* Adding records must not render arguments, even for records being retained. *)
assert (!forced_args = []);;
(* The longer candidate must be compared and discarded without rendering. *)
let dropped_label = "dropped";;
exptrace_add_tac test_tactic_name (make_record 200) (make_args dropped_label);;
assert (!forced_args = []);;
let selected = sampled_tac_logs (get_sampling_config ());;
assert (List.length (Hashtbl.find selected test_tactic_name) = test_max_num_records);;

let dump_dir = Filename.temp_file "tactictrace-lazy-args-" ".outdir";;
Sys.remove dump_dir;;
exptrace_dump dump_dir;;

(* Dumping renders each retained record once and never renders the discarded
   candidate. *)
assert (List.length !forced_args = test_max_num_records);;
List.iter
  (fun label ->
    assert (List.length (List.filter ((=) label) !forced_args) = 1))
  retained_labels;;
assert (not (List.mem dropped_label !forced_args));;

Sys.remove (Filename.concat dump_dir (test_tactic_name ^ ".json"));;
Sys.rmdir dump_dir;;
