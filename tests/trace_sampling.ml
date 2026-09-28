(* Exercise the public trace API without loading another TacticTrace checkout. *)
let fixture_assume = ASSUME;;
unset_jrh_lexer;;
open ExportTrace;;

let forced_args = ref [];;
let make_args id () =
  forced_args := id :: !forced_args;
  { names = ["id"]; types = ["int"]; values = [string_of_int id];
    exprs = [string_of_int id] };;

let make_record id nsub length : tac_record =
  let goal = ([],mk_var (String.make length 'x',bool_ty)) in
  { definition_line_number = ("fixture.ml",id);
    user_line_number = ("fixture.ml",id);
    goal_before = goal; goals_after = List.init nsub (fun _ -> goal);
    num_subgoals = nsub };;

(* Keep the former policy as a small independent oracle. Stable sorting also
   covers equal-length candidates at the replacement boundary. *)
let oracle = Hashtbl.create 8;;
let oracle_add name (r:tac_record) =
  let len = String.length (string_of_term (snd r.goal_before)) in
  let old = try Hashtbl.find oracle name with Not_found -> [] in
  let candidate = (r,lazy (make_args (snd r.user_line_number) ()),
                   { input_concl_str_len = len }) in
  let result =
    if List.length old < max_num_records then candidate :: old
    else if List.for_all (fun (_,_,i) -> i.input_concl_str_len < 100) old
    then old
    else
      let sorted = List.stable_sort
        (fun (_,_,a) (_,_,b) -> compare a.input_concl_str_len b.input_concl_str_len)
        (candidate :: old) in
      List.rev (List.tl (List.rev sorted)) in
  Hashtbl.replace oracle name result;;

let add name id nsub length =
  let r = make_record id nsub length in
  oracle_add name r;
  exptrace_add_tac name r (make_args id);;

let ids table name =
  List.map (fun ((r:tac_record),_,_) -> snd r.user_line_number)
    (Hashtbl.find table name);;

(* A conversion oracle catches any accidental application of tactic sampling
   to the existing eager conversion path. *)
let conv_oracle = ref [];;
let add_conversion id length =
  let input = mk_var (String.make length 'c',bool_ty) in
  let output = fixture_assume (mk_eq (input,mk_var ("rhs",bool_ty))) in
  let r : conv_record =
    { definition_line_number = ("fixture.ml",id);
      user_line_number = ("fixture.ml",id); input = input; output = output } in
  let candidate = (r,make_args id (),
                   { input_term_str_len = String.length (string_of_term input) }) in
  let old = !conv_oracle in
  conv_oracle :=
    if List.length old < max_num_records then candidate :: old
    else if List.for_all (fun (_,_,i) -> i.input_term_str_len < 50) old then old
    else List.rev (List.tl (List.rev (List.stable_sort
      (fun (_,_,a) (_,_,b) -> compare a.input_term_str_len b.input_term_str_len)
      (candidate :: old))));
  exptrace_add_conv "conversion" r (make_args id);;

let fixture_main () =
  let scenario = Sys.argv.(1) and output = Sys.argv.(2) in
  if scenario = "dump-only" then exptrace_dump output else begin
    Random.init 8147;
    let expected_global_draw = Random.bits () in
    Random.init 8147;
    (* Balanced data exceeds the capacity in every bucket. *)
    for i = 0 to 179 do
      if scenario = "noise" then begin
        ignore (Random.bits ());
        add "unrelated" (10000 + i) (i mod 3) 12
      end;
      add "balanced" (1000 + i) (i mod 3) 12
    done;
    for i = 0 to 99 do add "rare" (2000 + i) 1 12 done;
    add "rare" 2200 0 12;
    add "rare" 2201 3 12;
    (* Exercise the old replacement and early-freeze branches, including ties. *)
    for i = 0 to 59 do add "long" (3000 + i) (i mod 3) (160 - i) done;
    for i = 0 to 39 do add "ties" (4000 + i) (i mod 3) 110 done;
    for i = 0 to 49 do add "short" (5000 + i) 0 5 done;
    if scenario <> "noise" then assert (Random.bits () = expected_global_draw);
    assert (!forced_args = []);

    (* All three size filters must reject before creating or forcing arguments. *)
    let base = make_record 9000 0 10 in
    let too_many = (List.init 151 (fun _ -> ("a",fixture_assume (snd base.goal_before))),
                    snd base.goal_before) in
    let rec big_term n =
      if n = 0 then mk_var ("p",bool_ty)
      else mk_comb (mk_var ("f",mk_fun_ty bool_ty bool_ty),big_term (n - 1)) in
    let too_big = ([],big_term 1001) in
    List.iteri (fun i r -> exptrace_add_tac "filtered" r (make_args (9000+i)))
      [{ base with goal_before = too_many };
       { base with goal_before = too_big };
       { base with goals_after = [too_many]; num_subgoals = 1 };
       { base with goals_after = [too_big]; num_subgoals = 1 }];
    assert (not (Hashtbl.mem tac_logs "filtered"));
    assert (!forced_args = []);

    for i = 0 to 59 do add_conversion (6000+i) (100-i) done;
    let conv_ids xs = List.map (fun ((r:conv_record),_,_) -> snd r.user_line_number) xs in
    assert (conv_ids (Hashtbl.find conv_logs "conversion") = conv_ids !conv_oracle);
    let conv_base = { definition_line_number = ("fixture.ml",9100);
      user_line_number = ("fixture.ml",9100); input = snd too_big;
      output = fixture_assume (mk_eq (mk_var ("a",bool_ty),mk_var ("b",bool_ty))) } in
    let forbidden_args () = failwith "Filtered conversion forced its arguments" in
    exptrace_add_conv "filtered_conversion" conv_base forbidden_args;
    let tiny = mk_var ("tiny",bool_ty) in
    exptrace_add_conv "filtered_conversion"
      { conv_base with input = tiny; output = fixture_assume (mk_eq (tiny,tiny)) }
      forbidden_args;
    assert (not (Hashtbl.mem conv_logs "filtered_conversion"));
    forced_args := [];
    let retained_ids = Hashtbl.fold (fun _ rs acc ->
      List.fold_left (fun acc ((r:tac_record),_,_) -> snd r.user_line_number :: acc) acc rs)
      tac_logs [] in
    exptrace_dump output;
    assert (List.sort compare !forced_args = List.sort compare retained_ids);
    assert (not (List.exists (fun n -> n >= 9000 && n < 10000) !forced_args));

    if scenario = "legacy" then begin
      Hashtbl.iter (fun name _ -> assert (ids tac_logs name = ids oracle name)) oracle;
      Hashtbl.clear tac_logs;
      Hashtbl.iter (fun name rs -> Hashtbl.add tac_logs name rs) oracle;
      exptrace_dump (Sys.argv.(3))
    end
  end;;

fixture_main ();;
set_jrh_lexer;;
