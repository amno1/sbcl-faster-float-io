# Tests and benchmarks for faster number printing and reading in SBCL.
# See tests.md. Each part runs on its own build; set the paths to your
# checkouts (each built with ./make.sh) here or on the command line:
#
#   make ZMIJ=/path/to/sbcl-zmij PARSE_FLOAT=/path/to/sbcl-parse-float test
#
# UPSTREAM  plain upstream SBCL at the branches' base commit ("before")
# ZMIJ      branch sbcl-zmij: printing and FORMAT
# PARSE_FLOAT  branch sbcl-parse-float: reading and SB-EXT:PARSE-FLOAT
# BOTH      a build with both parts (branch sb-simd-512), for
#           single-roundtrip
# READ_FAST  branch sbcl-read-fast: the READ-TOKEN fast path (integers.md)
# INT_PRINT  branch sbcl-int-print: base-10 integer printing (integers.md)
# REPO      the SBCL repository with all the branches, for make summary
#
# Variables the scripts read, all optional, can be given the same way
# (make THREADS=16 test-long): THREADS, RUNS, LIMIT, DOUBLES, ORIGINAL_REV.

UPSTREAM    ?= $(HOME)/repos/sbcl-upstream
ZMIJ        ?= $(HOME)/repos/sbcl-zmij
PARSE_FLOAT ?= $(HOME)/repos/sbcl-parse-float
BOTH        ?= $(HOME)/repos/sb-simd-512
READ_FAST   ?= $(HOME)/repos/sbcl-read-fast
INT_PRINT   ?= $(HOME)/repos/sbcl-int-print
REPO        ?= $(HOME)/repos/sbcl

RUN = run-sbcl.sh --script

PRINT_TESTS = correctness vs-original fallback print-format fixed \
              format-fixed flonum-to-string buffer exponential general \
              transform
READ_TESTS  = parse-float parse-float-function
LONG_TESTS  = single-all single-roundtrip
BENCHMARKS  = benchmark format-bench read-bench real-data
INT_TESTS   = read-fast int-print
INT_BENCH   = profile-reader profile-printer read-fast-bench fast-path-misses \
              parse-integer-bench

.PHONY: help test test-print test-read test-long bench test-int bench-int \
        $(PRINT_TESTS) $(READ_TESTS) $(LONG_TESTS) $(BENCHMARKS) \
        $(INT_TESTS) $(INT_BENCH) supplemental third-party summary

help:
	@echo "make test          quick tests: test-print and test-read"
	@echo "make test-print    printing and FORMAT tests (ZMIJ)"
	@echo "make test-read     reading tests (PARSE_FLOAT)"
	@echo "make test-long     exhaustive runs, tens of minutes"
	@echo "make supplemental  Nigel Tao's test data (UPSTREAM and PARSE_FLOAT)"
	@echo "make third-party   parse-float against Quicklisp libraries"
	@echo "make bench         all benchmarks, before and after"
	@echo "make test-int      integer tests (READ_FAST and INT_PRINT)"
	@echo "make bench-int     integer benchmarks, before and after"
	@echo "make summary       what each patch series changes, and its size"
	@echo "make <name>        one test or benchmark, e.g. make fixed"

test: test-print test-read
test-print: $(PRINT_TESTS)
test-read: $(READ_TESTS)
test-long: $(LONG_TESTS)
bench: $(BENCHMARKS)
test-int: $(INT_TESTS)
bench-int: $(INT_BENCH)

# Printing tests, on ZMIJ. Tests comparing against SBCL's original code
# read it from the source tree of the build (ORIGINAL_REV picks the
# commit for flonum-to-string, exponential and general).
correctness:      ; $(ZMIJ)/$(RUN) tests/correctness.lisp all 1000000
vs-original:      ; $(ZMIJ)/$(RUN) tests/vs-original.lisp 2000000
fallback:         ; $(ZMIJ)/$(RUN) tests/fallback.lisp
print-format:     ; $(ZMIJ)/$(RUN) tests/print-format.lisp
fixed:            ; $(ZMIJ)/$(RUN) tests/fixed.lisp 1000000
format-fixed:     ; $(ZMIJ)/$(RUN) tests/format-fixed.lisp
flonum-to-string: ; $(ZMIJ)/$(RUN) tests/flonum-to-string.lisp
buffer:           ; $(ZMIJ)/$(RUN) tests/buffer.lisp
exponential:      ; $(ZMIJ)/$(RUN) tests/exponential.lisp
general:          ; $(ZMIJ)/$(RUN) tests/general.lisp
transform:        ; $(ZMIJ)/$(RUN) tests/transform.lisp

# Reading tests, on PARSE_FLOAT.
parse-float:          ; $(PARSE_FLOAT)/$(RUN) tests/parse-float.lisp 1000000
parse-float-function: ; $(PARSE_FLOAT)/$(RUN) tests/parse-float-function.lisp

# Needs the float-data and supplemental_test_files submodules:
# git submodule update --init
supplemental:
	$(UPSTREAM)/$(RUN) tests/supplemental.lisp
	$(PARSE_FLOAT)/$(RUN) tests/supplemental.lisp

# Needs Quicklisp with the parse-float and parse-number libraries.
third-party: ; $(PARSE_FLOAT)/$(RUN) tests/third-party.lisp 1000000

# Exhaustive runs. single-roundtrip with DOUBLES=1000000000 also reads
# back one billion random doubles.
single-all:       ; $(ZMIJ)/$(RUN) tests/single-all.lisp
single-roundtrip: ; $(BOTH)/$(RUN) tests/single-roundtrip.lisp

# Benchmarks: the same script on "before" and "after". Run them on an
# otherwise idle machine, on mains power.
benchmark:
	$(UPSTREAM)/$(RUN) benchmarks/benchmark.lisp 500000
	$(ZMIJ)/$(RUN) benchmarks/benchmark.lisp 500000
format-bench:
	$(UPSTREAM)/$(RUN) benchmarks/format-bench.lisp
	$(ZMIJ)/$(RUN) benchmarks/format-bench.lisp
read-bench:
	$(UPSTREAM)/$(RUN) benchmarks/read-bench.lisp
	$(PARSE_FLOAT)/$(RUN) benchmarks/read-bench.lisp
real-data:
	$(UPSTREAM)/$(RUN) benchmarks/real-data.lisp
	$(ZMIJ)/$(RUN) benchmarks/real-data.lisp
	$(PARSE_FLOAT)/$(RUN) benchmarks/real-data.lisp

# Integers (integers.md). read-fast and fast-path-misses compare the
# READ-TOKEN fast path with the normal reader in the same build.
read-fast: ; $(READ_FAST)/$(RUN) tests/read-fast.lisp
int-print: ; $(INT_PRINT)/$(RUN) tests/int-print.lisp
profile-reader:
	$(UPSTREAM)/$(RUN) benchmarks/profile-reader.lisp
	$(READ_FAST)/$(RUN) benchmarks/profile-reader.lisp
profile-printer:
	$(ZMIJ)/$(RUN) benchmarks/profile-printer.lisp
	$(INT_PRINT)/$(RUN) benchmarks/profile-printer.lisp
# Float reading with the fast path, against Eisel-Lemire alone.
read-fast-bench:
	$(PARSE_FLOAT)/$(RUN) benchmarks/read-bench.lisp
	$(READ_FAST)/$(RUN) benchmarks/read-bench.lisp
	$(PARSE_FLOAT)/$(RUN) benchmarks/real-data.lisp
	$(READ_FAST)/$(RUN) benchmarks/real-data.lisp
fast-path-misses: ; $(READ_FAST)/$(RUN) benchmarks/fast-path-misses.lisp
# PARSE-INTEGER as it is, against copies with r7's changes; any SBCL.
parse-integer-bench: ; $(PARSE_FLOAT)/$(RUN) benchmarks/parse-integer-bench.lisp

# What each patch series changes (definitions per file) and its size, from
# the branches in the SBCL repository REPO. Any SBCL.
summary: ; sbcl --script patch-stats.lisp $(REPO)
