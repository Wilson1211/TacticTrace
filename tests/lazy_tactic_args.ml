(* Verify that tactic argument rendering is deferred until trace dumping. *)

unset_jrh_lexer;;
open ExportTrace;;

let test_tactic_name = "__lazy_tactic_args_test__";;

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
let test_tac_logs = ExportTrace.tac_logs;;
let test_all_tac_records_interesting = ExportTrace.all_tac_records_interesting;;

set_jrh_lexer;;

let rec nested_conj n =
  if n = 0 then `T`
  else mk_conj (`T`,nested_conj (n - 1));;

let make_record n = make_record_from_term n (nested_conj n);;

let retained_labels =
  List.init test_max_num_records (fun i -> "retained-" ^ string_of_int i);;

let retained_record = make_record 50;;

List.iteri
  (fun _ label ->
    exptrace_add_tac test_tactic_name retained_record (make_args label))
  retained_labels;;

(* Adding records must not render arguments, even for records being retained. *)
assert (!forced_args = []);;
assert
  (not
    (test_all_tac_records_interesting
      (Hashtbl.find test_tac_logs test_tactic_name)));;

(* All retained goals exceed the interestingness cutoff, so this candidate is
   compared with them and then discarded as the longest goal. *)
let dropped_label = "dropped";;
exptrace_add_tac test_tactic_name (make_record 200) (make_args dropped_label);;
assert (!forced_args = []);;

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
