# Faster float printing and reading in SBCL

This is a summary of a set of SBCL patches that make printing and reading
floating-point numbers several times faster, without changing what is printed or
read. This folder contains everything used to check that claim and to measure
the speed: the tests, the benchmarks and their results.  [`tests.md`](tests.md)
explains how to run them, and [`details.md`](details.md) has a more concrete,
in-depth description of the changes.

The work is in two parts:

- **Printing**: Victor Zverovich's [zmij](https://github.com/vitaut/zmij)
  shortest-digit algorithm (`src/code/zmij.lisp`, hooked into
  `%flonum-to-digits` in `src/code/print.lisp`) and faster `format` float
  directives. Branch [`sbcl-zmij`](https://github.com/amno1/sbcl/tree/sbcl-zmij).

- **Reading**: the [Eisel-Lemire](https://arxiv.org/abs/2101.11408)
  algorithm from the [fast_float](https://github.com/fastfloat/fast_float)
  library as a fast path in the reader, and a new function
  `sb-ext:parse-float` (`src/code/reader.lisp`). Branch
  [`sbcl-parse-float`](https://github.com/amno1/sbcl/tree/sbcl-parse-float).

Printing and reading are in separate branches so each part can be
tested and benchmarked separately against stock SBCL.

Branch [`sb-simd-512`](https://github.com/amno1/sbcl/tree/sb-simd-512)
has both. That is my "everyday" SBCL; I put there everything so I can
use it myself.

## In short

  **Printing** a float with `prin1`, `princ`, `~A` or `~S` is about **5x
  faster** for values of moderate size (0.1 to 10^7) and **2-6x** on
  real-world data. The gain grows with the size of the exponent, because
  the old algorithm computed with integers of hundreds of digits for very
  large and very small numbers: averaged over the whole floating-point
  range, which consists mostly of such numbers, printing is 35x faster for
  doubles and 12x for singles. Producing the digits of a double alone is up
  to 68x faster, but the rest of printing (layout and streams) did not get
  that much faster.

  **`format` float directives** (`~F`, `~E`, `~G`, `~$`) are about 4-6x
  faster for values of moderate size, and 5-13x for small values (0.001
  to 0.1).

  **Reading** floats is about 1.3-1.7x faster for short and ordinary
  numbers (1.1-1.8x on real-world data) and about 6x faster for doubles
  with large exponents. A new function, **`sb-ext:parse-float`**, parses a
  float from a string like `parse-integer` parses an integer, 3-4.5x faster
  than `read-from-string`, and 5-6x faster than reading was before on
  real-world data.

  **Output is unchanged**, with one deliberate exception: subnormal floats
  (the tiny numbers below about 1e-308 for doubles and 1e-38 for singles)
  now print with their shortest digits, e.g. `1.42954e-39` instead of
  `1.4295402e-39`. Both read back as the same float.

  **Read results are unchanged.**

  The fast paths are for **64-bit platforms**. 32-bit platforms keep the
  original code.

## Why

SBCL printed floats with the Burger-Dybvig algorithm (1996), using bignum
arithmetic, and read them by building an exact rational number and converting
it. Both are correct, but slow. Printing a random double took about 2
microseconds, and reading one with a large exponent about 1.2
microseconds. Programs that write or read a lot of numbers, such as data files,
CSV, JSON, logs or numeric output, spend much of their time there.

Since 2018, a series of algorithms (Ryu, Schubfach, Dragonbox, and most recently
zmij) print floats with a few 64-bit and 128-bit multiplications and a table of
powers of ten. On the reading side, the Eisel-Lemire algorithm, used by
`fast_float`, Rust, Go and .NET, does the same in the other direction. These
patches bring both to SBCL.

## What was done

There are two parts. Each part is a series of small commits on its own branch
(see "Patches" below).

### 1. Shortest printing: zmij

[zmij](https://github.com/vitaut/zmij) is a recent shortest-digit algorithm by
Victor Zverovich (see [the blog
post](https://vitaut.net/posts/2025/faster-dtoa/)). It is ported to Lisp in
`src/code/zmij.lisp`, using only 64-bit integer arithmetic and a table of
128-bit powers of ten built at compile time.

`%flonum-to-digits`, behind `prin1` and friends, uses zmij for single and double
floats.

Digits are produced with an **SSE2** routine on x86-64 (16 digits at once, a
port of zmij's), with a portable fallback for other platforms.

`print-float` and `prin1-to-string` build the whole printed number in a stack
buffer, without a string stream.

One deliberate adaptation: when the last digit is an exact tie, upstream zmij
rounds to even, but SBCL has always rounded up. The port rounds up, so every
normal float prints exactly as before.

### 2. The `format` float directives

`~F`, `~E`, `~G` and `~$` with a digit count use a different, fixed-precision
mode of the old algorithm, with its own rounding rules. Instead of replacing it,
the patches add **exact fast paths that compute the same result** (the reasoning
is in [details.md](details.md), and tests compare them with the original on
millions of values), and fall back to the original code for anything else.

For the common case, where the requested precision is coarser than the float's
own, the old algorithm's result is just the value rounded to that position. That
is computed with exact integer arithmetic, a shift and a mask, including the old
algorithm's tie rule, which is neither round-half-up nor round-half-to-even
(10.5 rounds to 10, but 12.5 to 13), and its handling of values that round to
zero.

When the requested precision is finer than the float's (e.g. `~G` without a
digit count, or `~,20F`), the old algorithm's result is the shortest decimal in
the float's rounding interval, which is zmij's job.

`~wF` with only a width gets its digit position computed exactly too.

The formatted number is laid out in a stack buffer instead of three temporary
strings.

A compiler transform makes `(format nil "~,2F" x)` and other single float
directives with constant parameters build the string directly, without
`format`'s string stream.

### 3. Reading: Eisel-Lemire and `sb-ext:parse-float`

`make-float` in `src/code/reader.lisp` first tries a fast path adapted from
[fast_float](https://github.com/fastfloat/fast_float) (Daniel Lemire and
contributors). For up to 19 significant digits it is proven to give the
correctly rounded float from one 64x128-bit multiplication. Anything else falls
back to the original exact code: more digits, overflow, the `R` marker.

A new function, `sb-ext:parse-float (string &key start end junk-allowed)`
returns `(values float index)`, with the same conventions as `parse-integer`. It
accepts the reader's float syntax, plus plain integers, and returns what the
reader would, without the reader, readtable or stream. It is documented in the
manual.

The original algorithms stay in SBCL: they are the fallback for the rare cases
and for 32-bit platforms, and the definition of correct output.

## How we know it is correct

The guiding rule was: **the new code must produce exactly what the old code
produced**. Every check compares against the old code itself, or against an
exact mathematical reference, never against the new code's own expectations.

Two self-contained regression tests are added to SBCL's own test suite,
`tests/float-print.pure.lisp` and `tests/float-parse.pure.lisp`. The patches
pass SBCL's CI on GitHub, including the builds hosted by CLISP, CCL, CMUCL and
ECL, and the check that CLISP, CCL and CMUCL compile SBCL to the same bytes as
SBCL itself does. Besides these regression tests, the much longer test scripts
used during the work are in this folder and described in [`tests.md`](tests.md).

## Results

All numbers in this section were measured on 2026-10-09 in one session, on
x86-64 (my laptop, on mains power), in nanoseconds per call, best of 9
runs. "Before" is plain upstream SBCL at commit
[`c2aca591d`](https://github.com/sbcl/sbcl/commit/c2aca591d); "after" is the
[`sbcl-zmij`](https://github.com/amno1/sbcl/tree/sbcl-zmij) branch for printing
and [`sbcl-parse-float`](https://github.com/amno1/sbcl/tree/sbcl-parse-float)
for reading, both built on that commit. Individual numbers vary by 10-30%
between sessions; the ratios are stable. The benchmark files and the `make`
targets that run them are described in [`tests.md`](tests.md), and the full
output is in [`results`](results).

**Printing**, random bit patterns (the whole floating-point range):

|                            | before | after |
|----------------------------|-------:|------:|
| `flonum-to-digits`, double |  2,314 |    34 |
| `flonum-to-digits`, single |    548 |    26 |
| `prin1-to-string`,  double |  2,406 |    68 |
| `prin1-to-string`,  single |    628 |    54 |

**Printing and `format`**, values of moderate size, 0.1 to 10^7, spread evenly
over the magnitudes. That range suits prices, coordinates and measurements, but
not all data: see "Real-world data" below for how much of each kind of data
falls in it.

|                                     | 0.1 to 10^7: before | after | 0.001 to 0.1: before | after |
|-------------------------------------|--------------------:|------:|---------------------:|------:|
| `prin1-to-string`                   |                 330 |    60 |                  580 |    55 |
| `(format nil "~,2F" x)`             |                 390 |    95 |                  430 |    85 |
| `(format nil "~F" x)`               |                 355 |    90 |                  645 |    90 |
| `(format nil "~,3E" x)`             |                 610 |   135 |                1,455 |   145 |
| `(format nil "~G" x)`               |               1,270 |   210 |                2,850 |   225 |
| `(format nil "~,2G" x)`             |                 630 |   155 |                1,845 |   170 |
| `(format nil "~$" x)`               |                 430 |   105 |                  435 |    90 |
| `(format nil "~12F" x)`, width only |               1,030 |   265 |                1,660 |   340 |

The second pair of columns is for small values, from 0.001 to 0.1. The old code
is much slower there for most directives, because their shortest digits start
far to the right of the point; `~,2F` and `~$` of values below 0.01 take another
path, which was already fast.

**Reading** with `read-from-string`, the fast path on and off in the same build:

|                                | before | after |
|--------------------------------|-------:|------:|
| short (`1.5`, `12.25`)         |    130 |   100 |
| 17 digits, ordinary magnitude  |    310 |   180 |
| 17 digits, exponent up to ±300 |  1,240 |   200 |
| single-floats                  |    480 |   140 |

**`sb-ext:parse-float`** against `read-from-string`, on the same strings:

|                                | parse-float | read-from-string |
|--------------------------------|------------:|-----------------:|
| short                          |          20 |               90 |
| 17 digits, ordinary            |          60 |              190 |
| 17 digits, exponent up to ±300 |          70 |              210 |
| single-floats                  |          40 |              140 |

**Real-world data**: the number files of
[`float-data`](https://github.com/fastfloat/float-data) (geographic coordinates,
star catalogues, weather data, neural-network weights and more), up to 1M
numbers per file. Each line is read with `read-from-string` and the value
printed with `prin1-to-string`; `parse-float` reads the line with
`sb-ext:parse-float`. ns per number:

| file                      | type   | read before | read after | parse-float | print before | print after |
|---------------------------|--------|------------:|-----------:|------------:|-------------:|------------:|
| `bitcoin` (prices)        | double |         193 |        133 |          35 |          191 |          52 |
| `canada` (coordinates)    | double |         315 |        172 |          54 |          248 |          54 |
| `gaia` (star catalogue)   | double |         320 |        183 |          58 |          286 |          60 |
| `hellfloat64` (synthetic) | double |       1,287 |        205 |          74 |        1,984 |          68 |
| `marine_ik` (robotics)    | single |         153 |        104 |          24 |          121 |          41 |
| `mesh` (3D model)         | double |         143 |        106 |          26 |          149 |          50 |
| `mobilenetv3_large` (AI)  | single |         224 |        131 |          40 |          177 |          51 |
| `noaa_gfs_1p00` (weather) | double |         191 |        120 |          32 |          329 |          52 |
| `noaa_global_hourly_2023` | double |         114 |        100 |          21 |           92 |          49 |
| `numbers` (random 0-1)    | double |         237 |        151 |          39 |          220 |          53 |

On real data, reading with `read-from-string` is 1.1-1.8x faster (6x on the
synthetic `hellfloat64`), `sb-ext:parse-float` is 5-6.5x faster than reading
was, and printing is 2-6x faster (29x on `hellfloat64`). Every printed value
read back as the same float. The gains are largest for long numbers such as
`canada` and `gaia`, and smallest for short ones such as
`noaa_global_hourly_2023` (`1000.0`, `-2.6`), where the reader's and the
printer's own costs dominate.

How much of each file lies in the 0.1 to 10^7 range of the tables above:

| data                                                    | between 0.1 and 10^7 |
|---------------------------------------------------------|---------------------:|
| `bitcoin` (prices), `canada` (coordinates)              |                 100% |
| `gaia` (star catalogue), `noaa_global_hourly_2023`      |                  98% |
| `numbers` (random 0-1), `mesh` (3D model)               |               81-90% |
| `marine_ik` (robotics)                                  |                  65% |
| `noaa_gfs_1p00` (weather model)                         |                  46% |
| `mobilenetv3_large` (neural-network weights)            |                  13% |

Most of the rest are values between 0.001 and 0.1 (85% of the neural-network
weights), zeros, or values below 0.001 (22% of `noaa_gfs_1p00`). Printing small
values is no slower: shortest output does not depend on magnitude, and the files
with many small values gain as much as the others. For `format`, the table above
also shows values between 0.001 and 0.1.

What remains in `prin1`, `format` and `read-from-string` is now mostly their
general machinery (streams, directive handling, the reader), not the float
conversion.

## Compared with float-parsing libraries

`sb-ext:parse-float` against two Quicklisp libraries that parse floats from
strings: [`parse-float`](https://github.com/soemraws/parse-float)
(`parse-float:parse-float`) and
[`parse-number`](https://github.com/sharplispers/parse-number)
(`parse-number:parse-number`), with `read-from-string` for reference.  The test
is `third-party.lisp`.

**Correctness**: 1,000,000 random doubles and 1,000,000 random singles (both
signs, subnormals included) printed with `prin1-to-string` and parsed back. A
result must be the original float, bit for bit; an error counts as a failure.

| failures                 |  doubles | singles |
|--------------------------|---------:|--------:|
| `sb-ext:parse-float`     |        0 |       0 |
| `parse-float:parse-float`|  340,677 | 276,689 |
| `parse-number`           |        0 |       0 |

`parse-float` converts the integer and fraction parts to floats separately, adds
them and then scales by the exponent, rounding at each step. About a third of
the values come back wrong, nearly all one unit in the last place off (337,093
of the doubles, 271,436 of the singles). It also signals an error on some very
large and very small values (233 doubles, 3,270 singles). `parse-number` builds
the exact value as a rational and converts it once, so it is always right.

**Speed**, nanoseconds per string, best of 7, on strings that this test
generates itself (so `read-from-string` differs slightly from the reading tables
above):

|                                | `sb-ext:parse-float` | `parse-float` | `parse-number` | `read-from-string` |
|--------------------------------|---------------------:|--------------:|---------------:|-------------------:|
| short (`1.5`, `12.25`)         |                   20 |           130 |            180 |                 90 |
| 17 digits, ordinary            |                   50 |           210 |            330 |                160 |
| 17 digits, exponent up to ±300 |                   80 |           350 |          2,140 |                200 |
| single-floats                  |                   50 |           200 |            830 |                140 |

`sb-ext:parse-float` is 4 to 6.5 times faster than `parse-float` and 7 to 27
times faster than `parse-number`. These were run on the patched SBCL;
`parse-number` does not use the new reader fast path: its rational arithmetic
with powers of ten up to 10^300 is why it slows down so much with large
exponents.

## Some of the changes that might get noticed

Most notable is **subnormals print shorter**: e.g. `1.42954e-39` instead of
`1.4295402e-39`. The old printer gave them more digits than needed. Both forms
read back as the same float. This only matters to code that depends on the exact
printed digits of subnormals, which I expect to be rare.

There is a new function, **`sb-ext:parse-float`**, which uses the faster float
parser directly, without going through the Lisp reader. That saves the reader's
own overhead, roughly 70-140 ns per number: it is 3-4.5x faster than
`read-from-string`, and 5-18x faster than reading floats was before these
patches.

A compiler transform for **`(format nil "<one float directive>" x)`**.  The
output is the same, and in ordinary use the change is not visible, but the
disassembled code looks different.

Before, the call compiled to code that creates a string stream, writes the
number into it through the `~F` machinery, and returns the stream's contents.

Now it compiles to a direct call to a new internal function,
`sb-format::format-fixed-string` (or `format-exponential-string`,
`format-general-string` and `format-dollars-string` for `~E`, `~G` and `~$`),
which builds the result string without a stream. That saves about 20-50 ns per
call.

The result is the same string; the test compares compiled and interpreted format
on every kind of input.

It is listed because it changes what SBCL generates: a disassembly shows a call
to the new function instead of the old sequence, and tracing or redefining
SBCL's internal `format` functions, e.g.  `(trace sb-format::format-fixed-aux)`,
no longer catches these calls, because they do not go through those functions
any more.

Everything else prints and reads exactly as before, including how exact ties
round in `~F`, `~E` and `~G`. The aim was to disrupt as little as possible.

## Limits, what was left out and possible improvements

32-bit platforms keep the original code for everything: both zmij and
Eisel-Lemire need 64-bit integer arithmetic.

A few rare cases still use the original code, so they are correct but not
faster.

In **`format`**:

- values below one unit at a position in the ones place or higher, when they
  don't round up to that unit: typically `~,0F`, as in `(format nil "~,0F" 0.4)`
  or `(format nil "~,0F" 0.5)`; also `~,0G` of such values, `~E` with a scale
  factor of 0 or less and no decimals, like `(format nil "~,0,,0E" 0.4)`, and a
  width-only `~wF` whose width leaves no room for decimals. Values that round
  up, like 0.6 with `~,0F`, are fast, and so are all such values at positions
  after the decimal point, like `(format nil "~,2F" 0.001)`. Plain `~,0E` is not
  affected either, because it scales the significand to between 1 and 10.

- exact powers of two at precisions finer than the float's own spacing, e.g.
  1.0, 2.0, 0.5 or 1024.0 with `~,20F`, or under `~G` without a digit count. A
  power of two has a lopsided rounding interval, so the shortcut doesn't apply.

- subnormals at precisions finer than their spacing. The original algorithm
  deliberately uses a narrower interval for them.

In **reading**:

- numbers written with more than 19 significant digits, such as
  `0.10000000000000000000001`. Eisel-Lemire is only proven correct up to 19
  digits, so these are read with the original code.

No shared powers-of-ten tables: zmij and Eisel-Lemire use nearly the same
128-bit powers of ten (589 of 616 overlapping entries are identical; 27 differ
in the last bit by design). Sharing would save about 10 KB but couple the two
together; I am not sure whether that should be done.

Also, not done but possible: a fast path for reading more than 19 digits,
speeding up `format` calls with several directives, and 32-bit versions of zmij
and Eisel-Lemire.

## Things found along the way

These are useful if you would like to review this, and for anyone working on
SBCL's build:

Non-ASCII in source files:

  The "Ż" in "Żmij" breaks the CLISP-hosted build and `--without-sb-unicode`
  builds.

Floating-point math at build time:

  `#.(log 2d0 10d0)` is recorded in a cache during cross-compilation and
  checked against the new SBCL's own result. The last bit differed, so the code
  now uses integers there.

Code generation can depend on the host Lisp:

  The CLISP- and CMUCL-hosted builds compiled some `if` expressions differently
  from the SBCL-hosted build. The code was rewritten so that nothing depends on
  how far the compiler folds constants.

On 32-bit x86, loading a signaling NaN into a register fails CI:

  SBCL uses the x87 FPU, and the CPU signals an error as soon as a signaling NaN
  is loaded from memory into an FPU register, even before any arithmetic is done
  with it. On x86-64 that only happens when the NaN is used in a calculation or
  comparison.

On ARM floating-point overflow is not trapped:

  Reading a too-large number gives infinity rather than an error, before and
  after these patches.

A bug in SBCL's reader, now fixed upstream:

  Testing against Nigel Tao's parse-number test data
  ([`tests/supplemental.lisp`](tests/supplemental.lisp)) found that numbers with
  very many digits could be read as a wrong value. `(read-from-string "<1000
  nines>d0")` returned `1.0d251` instead of signaling an error, and a tiny
  number with a negative exponent read as a much larger one; the `R` marker was
  also affected (`1r400` read as 10^358). The exponent limit in
  `truncate-exponent` could cross zero. The fix is upstream as
  [`cf400f389`](https://github.com/sbcl/sbcl/commit/cf400f389).

## Patches

On branch `sbcl-zmij` (printing and `format`), about 2,700 lines including
tests: about 1,400 lines of code, 200 of tests and 1,200 of test data:

1. Use zmij for shortest float printing (with the SSE2 digit routine).
2. Print floats from a single buffer.
3. Build `prin1-to-string`/`princ-to-string` results without a string stream.
4. Round exact ties up, as SBCL always has.
5. Exact fast path for fixed-position digits (`~F`, `~E`, `~G`, `~$`).
6. Build `flonum-to-string`'s result without a string stream.
7. Lay out `~F`, `~$` and `~E` in stack buffers.
8. Exact fast path for relative digit positions (`~wF`).
9. Use zmij for positions finer than the float's spacing.
10. `~G`, values below one unit and exact ties: fewer digit passes and fallbacks.
11. Compile single `~F`, `~E`, `~G`, `~$` `format nil` calls without a string stream.
12. Tests: `tests/float-print.pure.lisp`.
13. Credits for zmij in `COPYING` and the source.

On branch `sbcl-parse-float` (reading and `sb-ext:parse-float`), about
1,070 lines: 360 of code (with comments), 200 of tests, 450 of test
data, and 70 of documentation and license notice.

1. Eisel-Lemire fast path for reading floats.
2. `sb-ext:parse-float`.
3. Build-host independence, the subnormal simplification, and 32-bit warnings.
4. Tests: `tests/float-parse.pure.lisp`.
5. Credits for `fast_float` in `COPYING`; `sb-ext:parse-float` in the manual.

The branches also contain follow-up commits (CI fixes, typos). The
[`patches`](patches) directory has them squashed into the topics above, one
patch per topic, made with `git format-patch` against upstream SBCL commit
[`c2aca591d`](https://github.com/sbcl/sbcl/commit/c2aca591d): `p1`-`p13` for
printing and `r1`-`r5` for reading, numbered as in the lists above. Each series
applies with `git am` on its own:

```sh
git am patches/p*.patch    # in the order p1, p2, ... p13
git am patches/r*.patch    # r1 ... r5
```

Applying both series on top of each other conflicts only in `COPYING`, where
`p13` and `r5` extend the same sentence; the
[`sb-simd-512`](https://github.com/amno1/sbcl/tree/sb-simd-512) branch has both,
merged. Applying all patches of a series gives exactly the source of its branch.

## Credits

**zmij:** Victor Zverovich, MIT license. https://github.com/vitaut/zmij

**fast_float:** Daniel Lemire and the fast_float authors, used under
  its MIT license. https://github.com/fastfloat/fast_float

**Eisel-Lemire**, and its proof without fallback for up to 19 digits:
  Michael Eisel, Daniel Lemire, and Noble Mushtak. Papers:

  - Daniel Lemire, "Number Parsing at a Gigabyte per Second", Software:
    Practice and Experience 51 (8), 2021. https://arxiv.org/abs/2101.11408

  - Noble Mushtak and Daniel Lemire, "Fast Number Parsing Without
    Fallback", Software: Practice and Experience 53 (7), 2023.
    https://arxiv.org/abs/2212.06644

**SBCL's original algorithms** (Burger-Dybvig, the reader's exact conversion)
  remain in SBCL as the reference and the fallback.

Both licenses' notices are included in SBCL's `COPYING`.

## License

The tests, benchmarks and documents in this repository are under the MIT
license; see [`LICENSE`](LICENSE). The data in the two submodules is not
part of this repository and not covered by that license: Nigel Tao's test data
in [`supplemental_test_files`](https://github.com/fastfloat/supplemental_test_files)
is under Apache 2.0, and
[`float-data`](https://github.com/fastfloat/float-data) states no license of
its own. The patches in [`patches`](patches) are contributions to SBCL
and follow SBCL's licensing.
