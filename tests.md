# Faster float printing and reading in SBCL: tests and benchmarks

Tests and benchmarks written while making SBCL print and read floats
faster.

## Running the files

The tests are in [`tests`](tests), the benchmarks in [`benchmarks`](benchmarks)
and the logs of the long runs in [`results`](results). The commands below are
run from the top folder.

All results below, and all numbers in [readme.md](readme.md), are from one
session on 2026-10-09: the three branches and plain upstream built on upstream
commit [`c2aca591d`](https://github.com/sbcl/sbcl/commit/c2aca591d), on x86-64,
on mains power. On the same builds SBCL's own test suite (`tests/run-tests.sh`)
passes on all three branches. The output of every run is in
[`results`](results): [`log-tests.txt`](results/log-tests.txt) for `make test`,
and one log per long run and benchmark.

Each part is tested and measured on its own branch, built on the same upstream
commit: [`sbcl-zmij`](https://github.com/amno1/sbcl/tree/sbcl-zmij) for
printing,
[`sbcl-parse-float`](https://github.com/amno1/sbcl/tree/sbcl-parse-float) for
reading, and plain upstream SBCL at the branches' base commit for "before". Only
`single-roundtrip.lisp`, which needs both parts, uses
[`sb-simd-512`](https://github.com/amno1/sbcl/tree/sb-simd-512), which has
both. To run everything, check out these four and build each with `./make.sh`.

While running these tests, a bug was found in SBCL's reader (in
`truncate-exponent`, and in how `make-float` used it), described under
`supplemental.lisp`. The fix is upstream as
[`cf400f389`](https://github.com/sbcl/sbcl/commit/cf400f389), after the 2.6.9
release; the branches contain it. Stock SBCL passes the tests without the fix,
since in this data the bug only shows in the new `sb-ext:parse-float`, so any
recent SBCL works as the "before" build. The only thing to watch: SBCL 2.6.9 runs
out of memory on the last file of `supplemental.lisp` with the default 1 GB heap,
so give it more with `--dynamic-space-size`, e.g. 8GB. Builds from current
upstream need nothing extra.

The [`makefile`](makefile) runs each file on the right build. Tell it where your
builds are, in the makefile or on the command line:

```sh
make UPSTREAM=~/src/sbcl ZMIJ=~/src/sbcl-zmij PARSE_FLOAT=~/src/sbcl-parse-float BOTH=~/src/sb-simd-512 test
```

| target              | runs                                                    |
|---------------------|---------------------------------------------------------|
| `make test`         | the quick tests: `test-print` and `test-read`           |
| `make test-print`   | the printing and `format` tests, on `ZMIJ`              |
| `make test-read`    | the reading tests, on `PARSE_FLOAT`                     |
| `make test-long`    | the exhaustive runs, tens of minutes                    |
| `make supplemental` | Nigel Tao's test data, on `UPSTREAM` and `PARSE_FLOAT`  |
| `make third-party`  | `sb-ext:parse-float` against Quicklisp libraries        |
| `make bench`        | every benchmark, before and after                       |
| `make <name>`       | one file, named as below without `.lisp`: `make fixed`  |

All variables are optional; the defaults are the paths on my machine.  Variables
for the scripts are given the same way, e.g.  `make THREADS=16 test-long`:

| variable       | default                     | meaning                                                         |
|----------------|-----------------------------|-----------------------------------------------------------------|
| `UPSTREAM`     | `~/repos/sbcl-upstream`     | plain upstream SBCL, the "before" build                         |
| `ZMIJ`         | `~/repos/sbcl-zmij`         | branch `sbcl-zmij`                                              |
| `PARSE_FLOAT`  | `~/repos/sbcl-parse-float`  | branch `sbcl-parse-float`                                       |
| `BOTH`         | `~/repos/sb-simd-512`       | a build with both parts                                         |
| `THREADS`      | 8                           | threads for the threaded tests                                  |
| `RUNS`         | 5 or 7                      | passes per benchmark; the best is reported                      |
| `LIMIT`        | 1,000,000                   | lines per file in `real-data.lisp`                              |
| `DOUBLES`      | 0                           | random doubles in `single-roundtrip.lisp`                       |
| `ORIGINAL_REV` | `c7621755f`                 | the original SBCL for `flonum-to-string`, `exponential`, `general` |

Tests that compare against SBCL's original code read it from the source tree of
the build that runs them, so no paths have to be set for that. Each file can
also be run directly, from the top folder, as `<build>/run-sbcl.sh --script
tests/<file>.lisp [count]`.

Tests exit with status 0 on success and 1 on failure, and print at most 50
failures; `make` stops at the first failing file. Most run in under a minute;
the long runs take tens of minutes (on my laptop). An optional count argument
sets the number of random inputs. Run the benchmarks on an otherwise idle
machine, on mains power.

The data for `supplemental.lisp` and `real-data.lisp` is in two
submodules from the [fastfloat project](https://github.com/fastfloat),
[`float-data`](float-data) and
[`supplemental_test_files`](supplemental_test_files); check them out
with `git submodule update --init`.

## Tests: printing

#### [`correctness.lisp`](tests/correctness.lisp)

Checks printed digits against an exact reference written with rational
arithmetic, independent of any printing algorithm. Each result must:

1. read back as the same float,
2. be shortest (no decimal with fewer digits reads back),
3. be closest among decimals of that length (ties allowed either way).

It also checks that `prin1` output reads back as the same float. Modes: `edge`
(edge cases), `random` (random singles and doubles), `all` (both), and
`single-all` (every positive finite single-float, long).

Result: about 2.6M values with `all 1000000` (edge cases plus 1M random singles
and 1M random doubles), checked against the exact rational reference; every
printed result reads back, is shortest and is closest. 0 failures.

```sh
make correctness
```

#### [`vs-original.lisp`](tests/vs-original.lisp)

Compares shortest digits with SBCL's original Burger-Dybvig printer, loaded from
the source without the zmij shortcut. Normal floats must match exactly, ties
included; subnormals, which zmij prints shorter, are counted separately.

Result: 5,444,287 checks with `2000000`, including ties, all powers of two and random
values; identical to the original printer for all normal floats.

```sh
make vs-original
```

#### [`fallback.lisp`](tests/fallback.lisp)

Checks the portable `%zmij-store-digits`, used on platforms other than x86-64
and loaded straight from `src/code/zmij.lisp`, against the built-in one (the
SSE2 VOP on x86-64). Compares digits and masks on 2M random inputs plus edge
cases.

Result: identical digits and masks for every input.

```sh
make fallback
```

#### [`print-format.lisp`](tests/print-format.lisp)

Checks that `prin1`, `prin1-to-string` and `princ-to-string` lay out the digits
exactly like SBCL's original printer: decimal point, padding zeros and exponent
marker, under all four `*read-default-float-format*` values. Covers every layout
boundary, 200k random singles and doubles, and pprint dispatch.

Result: identical layout to the original printer for every input.

```sh
make print-format
```

## Tests: `format`

#### [`fixed.lisp`](tests/fixed.lisp)

Checks the fixed-position digits behind `~F`, `~E`, `~G` and `~$`, with absolute
and relative positions, against SBCL's original `%flonum-to-digits`, loaded from
the source. Covers ties, carries across powers of ten, values rounding to zero,
and random values at any position.

Result: 9,407,520 checks with `1000000` (8,454,701 of them on the fast path) and
17,398,788 with `2000000`, of absolute and relative positions, ties and rounding
to zero; identical to the original algorithm.

```sh
make fixed
```

#### [`format-fixed.lisp`](tests/format-fixed.lisp)

End to end: 33 `format` float directives, including width-only `~wF`, on 66k
inputs (bignums, ratios, zero, huge, tiny and subnormal floats). Each is
formatted with the fast paths and again with them switched off; the strings must
be identical.

Result: 33 directives on 66k inputs (bignums, ratios, huge, tiny and subnormal
floats); the output is identical with the fast paths on and off.

```sh
make format-fixed
```

#### [`flonum-to-string.lisp`](tests/flonum-to-string.lisp)

Compares all five return values of `flonum-to-string` with SBCL's original
version from before any zmij work (upstream commit
[`c7621755f`](https://github.com/sbcl/sbcl/commit/c7621755f); override with
`ORIGINAL_REV`). Covers widths, digit counts, scales, `fmin` and exponents over
floats of every magnitude.

Result: 33,524,928 calls over widths, digit counts, scales and exponents;
identical to the original.

```sh
make flonum-to-string
```

#### [`buffer.lisp`](tests/buffer.lisp)

Checks `flonum-to-buffer`, the stack-buffer path of `~F` and `~$`, against
`flonum-to-string`: characters, length, leading and trailing point flags and
point position, over all argument combinations.

```sh
make buffer
```

#### [`exponential.lisp`](tests/exponential.lisp)

Compares `format-exp-aux` (`~E`, also used by `~G`) with SBCL's original from
`c7621755f`, over a grid of every `~E` parameter (w, d, e, k, overflow and pad
characters, marker, @) on ordinary, huge, tiny, zero and infinite values.

Result: together with `general.lisp`, 6.6M calls over every directive parameter;
identical to SBCL's original functions.

```sh
make exponential
```

#### [`general.lisp`](tests/general.lisp)

Compares `format-general-aux` (`~G`) with SBCL's original from
`c7621755f`, over a grid of every `~G` parameter (k includes NIL), and
checks `flonum-exponent-and-length` against `flonum-exponent` and
`flonum-to-string`.

Result: together with `exponential.lisp`, 6.6M calls over every
directive parameter; identical to SBCL's original functions.

```sh
make general
```

#### [`transform.lisp`](tests/transform.lisp)

Checks the compiler transform for `format` control strings that are a
single `~F`, `~E`, `~G` or `~$` directive. Compiled `(format nil
"<directive>" x)` must give the same string as `format` interpreting
it, for floats, infinities, NaN, rationals, integers, complexes and
non-numbers. Also checks that the transform fires, and
that it leaves `V` and `#` parameters, `~:F`/`~:E`/`~:G` and
multi-directive strings alone.

Result: 2,175 checks on floats, NaN, infinities, ratios and
non-numbers; compiled and interpreted `format` give the same strings.

```sh
make transform
```

## Tests: reading

#### [`parse-float.lisp`](tests/parse-float.lisp)

Checks the Eisel-Lemire fast path of the reader (`make-float/fast`):
every string is read with the fast path and again with it switched
off, and the results must be identical (the same float bit for bit, or
the same kind of error). Covers printed doubles and singles, random
decimals (1-25 digits, exponents up to ±400, every marker and sign),
exact halfway cases near 2^53 and 2^24, and overflow, underflow and
subnormal boundaries, under both default float formats.

Result: 10,006,588 strings (9,151,424 through the fast path) (printed floats, random decimals, halfway cases,
boundaries); identical results with the fast path on and off.

```sh
make parse-float
```

#### [`parse-float-function.lisp`](tests/parse-float-function.lisp)

Checks `sb-ext:parse-float`:

On valid float tokens it returns what `read-from-string` returns (bit
for bit, or both signal a parse error). It is correctly rounded,
against an exact rational reference. On whitespace, junk, signs,
`:start`/`:end`, `:junk-allowed` and non-simple strings it returns the
same index, and NIL or error, as `parse-integer`.



Result: 1,238,419 checks of values, errors, junk, whitespace and non-simple
strings; matches the reader, the exact reference and `parse-integer`.

```sh
make parse-float-function
```

#### [`supplemental.lisp`](tests/supplemental.lisp)

Reading against Nigel Tao's test data in the
[`supplemental_test_files`](https://github.com/fastfloat/supplemental_test_files)
submodule: about 5.3M number strings from several projects' test suites, many of
them hard cases (up to 1,024 digits, exact halfway cases, extreme exponents),
each with the bits of the nearest single and double.  Every string is read as a
double and as a single with `read-from-string` and `sb-ext:parse-float`, and
must give exactly those bits; numbers too large for the format must signal an
error.  Strings without a point or exponent are integers to the reader, so for
those only `sb-ext:parse-float` is checked. Any SBCL.

Result: 19,960,008 checks on `sbcl-parse-float`, 0 failures; on plain upstream,
which has no `sb-ext:parse-float`, the 9,423,626 checks of `read-from-string`
pass too. Output: [`log-supplemental.txt`](results/log-supplemental.txt).

The first run found one failure, and it was a bug in upstream SBCL's reader, not
in the new code, fixed since in upstream commit
[`cf400f389`](https://github.com/sbcl/sbcl/commit/cf400f389):
`truncate-exponent`, which limits the exponent before the exact conversion,
could scale numbers whose digits alone are out of range back into range. A
1,023-digit integer (about 1.2e1022) read as `1.23456701234567d248` instead of
signaling an error, and a 1 after 1,100 zeros times 10^-1 read as `1.0d-240`
instead of 0. `sb-ext:parse-float` inherited it by using the same function.  The
fix keeps the limit from crossing zero, so such numbers still overflow or
underflow.

```sh
make supplemental
```

#### [`third-party.lisp`](tests/third-party.lisp)

Compares `sb-ext:parse-float` with two Quicklisp libraries that parse floats,
`parse-float` and `parse-number`. Random doubles and singles are printed and
parsed back by all three, and the failures of each are counted; the speed of all
three and of `read-from-string` is measured on four kinds of string. Only
failures of `sb-ext:parse-float` make the test fail. Needs Quicklisp with both
libraries installed.

Result: `sb-ext:parse-float` and `parse-number` 0 failures; `parse-float`
340,677 of 1M doubles and 276,689 of 1M singles wrong. The speed table is in
[readme.md](readme.md). Output:
[`log-third-party.txt`](results/log-third-party.txt).

```sh
make third-party
```

## Long runs

#### [`single-all.lisp`](tests/single-all.lisp)

Every positive finite single-float printed by zmij and by SBCL's original
printer (loaded from the source). Normal floats must match exactly; subnormal
differences are counted. Threaded; optional start and end bit patterns run a
sub-range.

Result: all 2,139,095,039 positive finite single-floats, 0 failures; the
4,513,047 subnormals that zmij prints shorter are counted, not failures. 313 s
on 16 threads. Output: [`log-single-all.txt`](results/log-single-all.txt).

```sh
make single-all
```

#### [`single-roundtrip.lisp`](tests/single-roundtrip.lisp)

Every positive finite single-float printed with `prin1-to-string` and read back
with both `read-from-string` and `sb-ext:parse-float`; both must give the same
float bit for bit. `DOUBLES` adds that many random doubles. Needs a build with
both the printer and the reader work, such as
[`sb-simd-512`](https://github.com/amno1/sbcl/tree/sb-simd-512). Threaded;
optional start and end bit patterns run a sub-range (`1 1` skips the singles).

Results:

  All 2,139,095,039 positive finite single-floats printed and read back with
  both `read-from-string` and `sb-ext:parse-float`: 0 failures.

  With `DOUBLES=1000000000`, also one billion random doubles. There are
  2^64 doubles, too many to print and read them all, so the test picks
  random ones (both signs, subnormals included): 0 failures.

The output of both runs: [`log-round-trip.txt`](results/log-round-trip.txt)
(singles only) and
[`log-round-trip-1b-doubles.txt`](results/log-round-trip-1b-doubles.txt)
(singles and one billion doubles).

```sh
make THREADS=16 single-roundtrip
make THREADS=16 DOUBLES=1000000000 single-roundtrip
```

## Benchmarks

#### [`benchmark.lisp`](benchmarks/benchmark.lisp)

Nanoseconds per call for `flonum-to-digits`, `prin1-to-string` and `prin1` on
random singles and doubles, and for `flonum-to-digits` at position -2 (the
digits behind `~,2F`) on values from 0.1 to 10^7.  Any SBCL.

```sh
make benchmark
```

Its random-bit-pattern figures are where readme.md's "35x for doubles and 12x
for singles" come from. Output:
[`log-bench-print.txt`](results/log-bench-print.txt).

What "random bit patterns" means: the benchmark fills a float with random bits,
so the exponents are spread evenly over the whole range the format can hold. For
doubles, a typical value is something like 3.7e-142 or 8.1e+213. Numbers near 1
are a small minority. That's the opposite of most real data: in the real-world
files of `real-data.lisp`, most values lie between 0.001 and 10^7.

Why: the old printer computes with exact integers scaled by powers of ten. For a
value like 1e-200, those are integers with hundreds of digits, so every step is
slow. zmij does the same job with a fixed amount of 64-bit and 128-bit
arithmetic, whatever the exponent. So the gain grows with the size of the
exponent:

- **Values of moderate size:** about 5x (`prin1-to-string` 330 -> 60 ns on
  values from 0.1 to 10^7).
- **Extreme exponents:** far more than 35x, since 35x is the average over the
  whole range.

Why singles gain less: a single-float's exponent only reaches about ±38, so the
old printer's integers never got very large. It was "only" about 600 ns for
singles, against about 2,400 for doubles.

In practice the gain is near 35x for code that prints very large or very small
doubles, and 2-6x for the real-world data of `real-data.lisp`.

#### [`format-bench.lisp`](benchmarks/format-bench.lisp)

Nanoseconds per call for every float `format` directive and `prin1-to-string`,
on doubles in two ranges: 0.1 to 10^7 (prices, coordinates, measurements) and
0.001 to 0.1 (small values such as neural-network weights; `~,2F` of values
below 0.01 takes a separate path). Each range is spread evenly over its
magnitudes. Any SBCL. Output:
[`log-bench-format.txt`](results/log-bench-format.txt).

```sh
make format-bench
```

#### [`read-bench.lisp`](benchmarks/read-bench.lisp)

Float reading: `read-from-string` of short, ordinary 17-digit and wide-exponent
tokens and of single-floats, against the conversion step alone and against
reading an integer (the reader's fixed cost); the fast path on and off;
`sb-ext:parse-float`. Any SBCL. Output:
[`log-bench-read.txt`](results/log-bench-read.txt).

```sh
make read-bench
```

#### [`real-data.lisp`](benchmarks/real-data.lisp)

Reading and printing real-world numbers: the files of the
[`float-data`](https://github.com/fastfloat/float-data) submodule (geographic
coordinates, star catalogues, weather data, neural-network weights, prices, a 3D
mesh, plus two synthetic files), one number per line. For each file it times
`read-from-string` and, where present, `sb-ext:parse-float` of each line, and
`prin1-to-string` of each value; every printed value must read back as the same
float. Files marked FP32 in the data set are read as singles. `LIMIT` (default
1M) caps the lines per file. Any SBCL.

Result: every value of every file printed and read back, 0 failures, on plain
upstream and on both branches. Output:
[`log-real-data.txt`](results/log-real-data.txt); the table is in
[readme.md](readme.md).

```sh
make real-data
```
