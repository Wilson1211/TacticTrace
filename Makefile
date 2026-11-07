OCAMLC = ocamlc
OCAMLFIND = ocamlfind
OCAMLLEX = ocamllex
OCAMLYACC = ocamlyacc
OCAMLCPARAM = -g

TYPES_SOURCES = ocamlTypes.ml types_parser.ml types_lexer.ml
TYPES_OBJECTS = $(TYPES_SOURCES:.ml=.cmo)

# Set the HOLLIGHT_DIR to <this Makefile>/..
HOLLIGHT_DIR?=$(dir $(abspath $(lastword $(MAKEFILE_LIST))))/..

# If a local OPAM switch exists at $(HOLLIGHT_DIR)/_opam, prepend its bin
# directory to PATH so that ocamlfind, ocamlc, etc. are picked up even when
# this Makefile is invoked from an environment that has not run
# `eval $(opam env)`.
# $(HOLLIGHT_DIR) normally ends in '/..', so normalize it before testing for the
# directory: the unnormalized form is not matched by $(wildcard) on every make.
# GNU Make 3.81, which macOS ships, looks up a recipe command that runs without
# a shell in the PATH that make started with and ignores the exported one, so
# the tools that recipes run directly are also given by their full path.
# $(OCAMLC) stays a bare name because recipes pass it to ocamlfind, which runs
# it with the exported PATH.
OPAM_BIN := $(abspath $(HOLLIGHT_DIR)/_opam/bin)
ifneq ($(wildcard $(OPAM_BIN)),)
  export PATH := $(OPAM_BIN):$(PATH)
  OCAMLFIND := $(OPAM_BIN)/ocamlfind
  OCAMLLEX := $(OPAM_BIN)/ocamllex
  OCAMLYACC := $(OPAM_BIN)/ocamlyacc
endif

TESTS =\
  examples/tactic.ml \
  examples/conv.ml

TEST_OUTPUTS = $(TESTS:.ml=.outdir)
LAZY_TACTIC_ARGS_TEST = tests/lazy_tactic_args.native


all: types_test tracer

tracer: $(TYPES_OBJECTS) tracer.ml
	$(OCAMLFIND) $(OCAMLC) -package compiler-libs.common $(OCAMLCPARAM) -linkpkg -o tracer $^

types_test: $(TYPES_OBJECTS) types_test.ml
	$(OCAMLFIND) $(OCAMLC) $(OCAMLCPARAM) -o $@ $^

types_parser.ml types_parser.mli: types_parser.mly
	$(OCAMLYACC) types_parser.mly

types_lexer.ml: types_lexer.mll
	$(OCAMLLEX) types_lexer.mll

%.cmo: %.ml
	$(OCAMLFIND) $(OCAMLC) -package compiler-libs.common $(OCAMLCPARAM) -c $<

%.cmi: %.mli
	$(OCAMLFIND) $(OCAMLC) -package compiler-libs.common $(OCAMLCPARAM) -c $<

# Dependencies
types_test.cmo: ocamlTypes.cmo types_parser.cmo types_lexer.cmo
types_parser.cmo: types_parser.ml types_parser.cmi ocamlTypes.cmo ocamlTypes.cmi
types_lexer.cmo: types_lexer.ml types_parser.cmo
ocamlTypes.cmo: ocamlTypes.ml

# Collect the traces of the examples, then compare them against the expected
# traces in examples/*.answer .
test: test-examples test-lazy-tactic-args test-trace-sampling

test-examples: $(TEST_OUTPUTS)
	HOLLIGHT_DIR=$(HOLLIGHT_DIR) ./check-answers.sh

# This fixture calls the trace API directly, so it can observe exactly when an
# argument generator runs without going through the AST instrumentation.
test-lazy-tactic-args: $(LAZY_TACTIC_ARGS_TEST)
	./$(LAZY_TACTIC_ARGS_TEST) > tests/lazy_tactic_args.hollog

# Inline the collector and fixture while keeping original file names and lines.
tests/lazy_tactic_args_wrapped.ml: tests/lazy_tactic_args.ml exportTrace.ml
	$(HOLLIGHT_DIR)/hol.sh inline-load $< $@

$(LAZY_TACTIC_ARGS_TEST): tests/lazy_tactic_args_wrapped.ml
	$(HOLLIGHT_DIR)/hol.sh compile $< -o tests/lazy_tactic_args.cmx
	$(HOLLIGHT_DIR)/hol.sh link tests/lazy_tactic_args.cmx -o $@

# Use a fresh build for each invocation, including when HOL Light changes.
test-trace-sampling:
	python3 -B tests/build_trace_sampling.py "$(HOLLIGHT_DIR)" --test

examples/%.outdir: examples/%.ml tracer
	@if [ "$$($(HOLLIGHT_DIR)/hol.sh -use-module)" != "1" ]; then \
	  echo "Error: HOL Light at $(HOLLIGHT_DIR) was not built with HOLLIGHT_USE_MODULE=1,"; \
	  echo "       so no traces can be collected. Rebuild it with"; \
	  echo "         HOLLIGHT_USE_MODULE=1 make"; \
	  exit 1; \
	fi
	$(HOLLIGHT_DIR)/hol.sh inline-load $< $(basename $<)_inlined.ml
	HOLLIGHT_DIR=$(HOLLIGHT_DIR) $(HOLLIGHT_DIR)/TacticTrace/modify-proof.sh $(basename $<)_inlined.ml $(basename $<)_inlined_wrapped.ml $(basename $<).outdir
	$(HOLLIGHT_DIR)/hol.sh compile $(basename $<)_inlined_wrapped.ml -o $(basename $<).cmx
	$(HOLLIGHT_DIR)/hol.sh link $(basename $<).cmx -o $(basename $<).native
	$(basename $<).native > $(basename $<).hollog # Use cat to strip ANSI color codes


clean:
	rm -f *.cmo *.cmi tracer types_test types_parser.ml types_parser.mli types_lexer.ml kernel_wrapper.ml
	rm -rf $(TEST_OUTPUTS) examples/*.cm* examples/*_inlined* examples/*.o examples/*.hollog examples/*.native
	rm -f tests/lazy_tactic_args_wrapped.ml tests/lazy_tactic_args.cm* tests/lazy_tactic_args.o tests/lazy_tactic_args.hollog $(LAZY_TACTIC_ARGS_TEST)

.PHONY: all clean test test-examples test-lazy-tactic-args test-trace-sampling
