if [ "$#" -ne 3 ]; then
  echo "modify-proof.sh <input(inlined).ml> <output.ml> <default trace dir>"
  exit 1
fi
input=$1
input_no_linedir=${input%.ml}.nolinedir.ml
input_mli=${input_no_linedir%.ml}.mli
input_bin=${input_no_linedir%.ml}.marshalled.bin
output=$2
echo "==================== tactic logger: modify-proof.sh =================="
echo "  - input: $input"
echo "  - output: $output"
echo "======================================================================"
dumpdir=$3

export TACLOGGER_DIR=${HOLLIGHT_DIR}/TacticTrace

basedir=${TACLOGGER_DIR}

# Remove the line number directives first.
python3 ${TACLOGGER_DIR}/remove-linenum-dirs.py $input $input_no_linedir

${basedir}/get-ast.sh $input_no_linedir
# get-ast.sh creates input_bin
${basedir}/tracer modify $input $input_bin $input_mli ${basedir}/hol_lib_inlined.mli ${output}.org

head -2 ${output}.org > $output
echo "(* --- exportTrace.ml --- *)" >> $output
cat ${basedir}/exportTrace.ml >> $output
echo "(* --- kernel_wrapper.ml --- *)" >> $output
cat ${basedir}/kernel_wrapper.ml >> $output
echo "(* --- sampling_runtime.ml --- *)" >> $output
cat ${basedir}/sampling_runtime.ml >> $output
echo "" >> $output
# The default trace directory, used unless the sampling settings name one.
# Escape backslashes and double quotes so the path is a valid OCaml string.
dumpdir_ocaml=$(printf '%s' "$dumpdir" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
printf 'exptrace_set_default_dir "%s";;\n' "$dumpdir_ocaml" >> $output
tail -n +3 ${output}.org >> $output
echo "exptrace_dump ();;" >>$output

rm $input_bin $input_no_linedir
