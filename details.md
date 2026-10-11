# Implementation notes

The details behind [readme.md](readme.md): how each part works, and what each
step gained. Each figure is the gain from that step alone, measured in its own
session when the step was made, so they don't add up and later steps change
earlier numbers; the final numbers are in [readme.md](readme.md). Benchmark
numbers vary by up to about 2x between sessions on this machine, so compare
figures only within one benchmark run.

## Printing

### The zmij core

"zmij core" is `sb-impl::zmij-decimal`: the conversion alone, without digit
output. Exact integer ranges for the exponents, digits and shifts
(`zmij-dec-exp`, `zmij-digit`, `zmij-shift` = `(integer 3 7)` and others),
explicit 64-bit wraparound with `logand`, and the known shift range, which makes
extra `ldb` masks unnecessary, keep every intermediate value in a machine word.
The disassembly of the core functions (`zmij-double-regular` and the others)
contains no call to generic arithmetic and no allocation.

The core is close to the C implementation, which takes about 10-20 ns per double
on an Apple M1, according to Victor Zverovich's blog post. Most of the remaining
`prin1` time goes to digit emission and stream output, not to the conversion.

An exact tie in the last digit of the shortest output rounds up, as it always
has in SBCL: the single-float 171657.625 prints as 171657.63. Original zmij
rounds such ties to even. The port changes that in three places in
`src/code/zmij.lisp`, each commented: the special case for a remaining digit of
exactly 2.5 is removed in the two regular paths, and the irregular path adds a
bias of 2^63 (exactly one half) instead of 2^63 - 1 before truncating, so a tie
rounds up. [`vs-original.lisp`](tests/vs-original.lisp) checks that every normal
float prints exactly as before, ties and all powers of two included.

Tests: [`correctness.lisp`](tests/correctness.lisp),
[`vs-original.lisp`](tests/vs-original.lisp),
[`single-all.lisp`](tests/single-all.lisp). Benchmark:
[`benchmark.lisp`](benchmarks/benchmark.lisp) (the "zmij core" row), run against
stock SBCL with `make benchmark` (see [tests.md](tests.md)).

### Digit output

Digit output follows the scalar version of `to_bcd8` in the original
[zmij](https://github.com/vitaut/zmij) (`zmij.cc`). The significand is split
into 8-digit groups, each group is converted to one BCD digit per byte with
three multiply-and-shift steps, and leading and trailing zeros are found by
counting zero bytes (`integer-length`) instead of by division. Compared with the
earlier truncate-by-10 loop, this took `flonum-to-digits` from 72 to 66 ns and
`prin1-to-string` from 184 to 172 ns for doubles.

Digit output: on x86-64, one SSE2 VOP (`%zmij-store-digits`, a port of zmij's
SSE2 path) converts two 8-digit groups to 16 ASCII digits, stores them into a
stack-allocated base-string with a single `movdqu`, and returns a `pmovmskb`
mask of nonzero digits, so leading and trailing zeros need no division. SSE2 is
part of the x86-64 baseline, so no CPU dispatch is needed, and nothing beyond
SSE2 is used: 16 digits fill one XMM register, so AVX2 would not help. Other
platforms use the portable version of the same function (BCD via multiply and
shift). `print-float` and `flonum-to-digits` write or copy that buffer directly
instead of taking one callback per digit. Compared with the previous BCD
version, `prin1` to a null stream went from 144 to 70 ns for doubles. Most of
what remains in `prin1-to-string` is the string stream machinery.

Tests: [`fallback.lisp`](tests/fallback.lisp) (the portable version against the
SSE2 VOP), and every printing test through the printer. Benchmark:
[`benchmark.lisp`](benchmarks/benchmark.lisp).

### `print-float` and `prin1-to-string`

Single-buffer output: `print-float` assembles the digits, decimal point, padding
zeros and exponent (marker and digits, as `print-float-exponent` would print
them) in a 24-character stack buffer, then calls `write-string` once. That is
its only remaining function call; the digits are copied with an inline loop,
because `replace` went through an out-of-line `ub8-bash-copy`. Measured in one
session on doubles: `print-float` to a null stream 52 -> 42 ns, `prin1` to a
null stream 66 -> 56 ns, `prin1-to-string` 98 -> 84 ns.

String fast path: `stringify-object` (behind `prin1-to-string` and
`princ-to-string`) builds finite nonzero single and double floats directly with
`zmij-float-chars` and returns `(subseq buffer 0 n)`, with no string output
stream. Zero, infinities, NaN, and floats that a pprint dispatch entry applies
to while `*print-pretty*` is on keep the general path. `print-object` methods
on floats are not allowed (CLHS 11.1.2.1.2), so pprint dispatch is the only user
hook to respect. Within one session, `prin1-to-string` went from 84 to 62 ns for
doubles and now costs about the same as `prin1` to a null stream (58
ns). `print-format.lisp` checks this path, `princ-to-string` and the special
cases.

Tests: [`print-format.lisp`](tests/print-format.lisp),
[`correctness.lisp`](tests/correctness.lisp). Benchmark:
[`benchmark.lisp`](benchmarks/benchmark.lisp).

## `format`

### Fixed positions: `~F`, `~E`, `~G`, `~$`

Fixed precision: with an absolute position, SBCL's `%flonum-to-digits` generates
the shortest digits within a closed interval around the value. Its radius is the
larger of half a unit at 10^position and the float's half-gap. When 10^position
>= 2^e (the common case, e.g. `~,2F` of ordinary values), the only decimal in
that interval is the value rounded to a multiple of 10^position.

`flonum-to-digits/position` computes that exactly: a fixnum shift and mask in
the common case, exact integer arithmetic otherwise. Exact ties, results that
round to zero, finer positions, relative positions and long-floats keep the
original code, so the output is identical by construction and by test (at this
step; later steps put ties, results that round to zero and relative positions on
the fast path too, and finer positions use zmij; see below). zmij's original
fixed-precision mode rounds differently (half to even), so the outputs would not
match. Measured on values from 0.1 to 10^7, in one session: `flonum-to-digits`
at position -2 went from 230 to 40-55 ns (`benchmark.lisp`), `(format nil
"~,2F")` from 400 to 160 ns, `~$` from 425 to 185 ns, and `~,3E` from 435 to 285
ns. Most of what remains is `format`'s own machinery (`flonum-to-string` uses a
string output stream).

`flonum-to-string`: the result is built in one string of exactly the right
length instead of a string output stream, and digits are copied with loops
specialised on the digit string's type (`replace` from a base string into a
character string was 23% of `~,2F`). In one session, `(format nil "~,2F")` went
from 175 to 135 ns, `~$` from 190 to 140 ns, and `~,3E` from 290 to 240 ns. Most
of what is left is `format`'s own directive handling and its output
stream.

The final numbers for every directive are in [readme.md](readme.md).

Tests: [`fixed.lisp`](tests/fixed.lisp) (positions against the original
`%flonum-to-digits`), [`flonum-to-string.lisp`](tests/flonum-to-string.lisp)
(`flonum-to-string` against the original),
[`format-fixed.lisp`](tests/format-fixed.lisp) (end to end). Benchmarks:
[`format-bench.lisp`](benchmarks/format-bench.lisp), and
[`benchmark.lisp`](benchmarks/benchmark.lisp) for `flonum-to-digits` at position
-2.

### Stack buffers for `~F`, `~$` and `~E`

`~F` and `~$` through a stack buffer: `flonum-position-decimal` returns the
rounded integer instead of a digit string, `flonum-to-buffer` lays out digits,
zeros and the point in a 64-character `dynamic-extent` buffer in
`format-fixed-aux` and `format-dollars`, and the buffer is written once. The
layout code (`flonum-layout`) is shared with `flonum-to-string`. Anything that
does not fit, or is off the exact fast path, uses `flonum-to-string` as
before. `format-fixed.lisp` disables every fast path by replacing
`flonum-position-decimal` with `(constantly nil)`, so it compares against the
original code. In three consistent runs: `(format nil "~,2F")` went from 135 to
110-115 ns (original: 385), and `~$` from 140 to 125 ns (original: 400).

`~E`: `format-exp-aux` lays out the significand with `flonum-to-buffer` and
writes the exponent's digits into a small stack buffer instead of calling
`decimal-string`, which ran `write-to-string` through a string stream. In three
consistent runs, `(format nil "~,3E")` went from 240 to 165 ns (original: about
370).

Tests: [`buffer.lisp`](tests/buffer.lisp) (the buffer against
`flonum-to-string`), [`exponential.lisp`](tests/exponential.lisp) (`~E` against
the original), [`format-fixed.lisp`](tests/format-fixed.lisp).  Benchmark:
[`format-bench.lisp`](benchmarks/format-bench.lisp).

### Width only: `~wF`

Relative positions (`~wF`, a width without a digit count):
`flonum-relative-position` computes the absolute position that the original
derives from a number of digits, exactly, on integers: the smallest k >= 0 with
10^k >= value + half-gap, then k - n or k - n - 1 depending on whether rounding
would reach 10^k. The absolute fast path does the rest; anything it does not
handle falls back as before. `(format nil "~12F")` went from 940 to about 305
ns. `~G` without a digit count (about 485 ns) does not use this path.

Tests: [`fixed.lisp`](tests/fixed.lisp) (relative positions),
[`format-fixed.lisp`](tests/format-fixed.lisp) (width-only directives).
Benchmark: [`format-bench.lisp`](benchmarks/format-bench.lisp) (`~12F`).

### Positions finer than the float, and `~G`

Positions finer than the float's spacing (e.g. `~G` without a digit count, or
`~,20F`): when half a unit at the position is at most the float's half-gap, the
original's interval is the float's own rounding interval, made closed. Its
result is then the shortest decimal in that closed interval, which is zmij with
a new `closed` option (the interval includes its endpoints even for an odd
significand). Powers of two (asymmetric interval), the mixed zone and subnormals
still fall back. `fixed.lisp` includes odd-significand doubles and singles above
2^53 and 2^24, where interval endpoints are short decimals; about 9% of those
print differently closed vs open, and all match the original. `(format nil
"~G")` went from about 485 to 300 ns.

`~G` without a digit count needs the shortest digits' exponent and their printed
length, and used to generate the digits twice for them (`flonum-exponent`, then
`flonum-to-string`). `flonum-exponent-and-length` gets both from one zmij
call. Measured A/B in one process (switching the helper off), on a loaded
machine: 555 -> 415 ns.

Tests: [`fixed.lisp`](tests/fixed.lisp), [`general.lisp`](tests/general.lisp)
(`~G` and `flonum-exponent-and-length` against the original). Benchmark:
[`format-bench.lisp`](benchmarks/format-bench.lisp) (`~G`).

### Values below one unit, and ties

Values below one unit at the position: when the value rounds up to one unit, the
result is digit 1, as for any other value. When it is at most half a unit and
the position is below zero (e.g. `~,2F` of 0.001), the original always returns k
= 0 with the digits "0": it stops at the first digit, which is 0 because the
value is below 0.1. Both are now on the fast path. At positions >= 0 the
original returns unrounded digits for such values (`0.4` at position 0 gives
"4"); those still fall back, as do exact ties. `fixed.lisp` covers this region
at positions -12 to 3. For values between 1e-6 and 1e-2, `(format nil "~,2F")`
takes 190 ns, against 1210 ns with every fast path switched off (same process,
loaded machine).

Exact ties at the requested position, where the value lies exactly halfway
between q and q+1 units: the old algorithm does not really round. It returns the
shortest decimal in the closed interval [q, q+1], so it picks q when q ends in 0
(a decimal with one digit fewer) and q+1 otherwise. At position 0, i.e. without
decimals:

| value | old algorithm | round half up | round half to even |
|------:|--------------:|--------------:|-------------------:|
|   9.5 |            10 |            10 |                 10 |
|  10.5 |            10 |            11 |                 10 |
|  11.5 |            12 |            12 |                 12 |
|  12.5 |            13 |            13 |                 12 |

So it matches neither common rule. In detail: the original scans from the most
significant digit and stops at the first candidate in the closed interval [q,
q+1], so it returns q when q is a multiple of 10 (e.g. 10.5 at position 0 gives
"10.") and q+1 otherwise (11.5 gives "12.", 9.5 gives
"10."). `flonum-position-decimal` does the same now. Still falling back: powers
of two whose interval is only partly widened, subnormals at positions finer than
their spacing, and values below half a unit at positions >= 0, where the
original returns unrounded digits.

Tests: [`fixed.lisp`](tests/fixed.lisp) (positions -12 to 3, ties),
[`format-fixed.lisp`](tests/format-fixed.lisp). Benchmark:
[`format-bench.lisp`](benchmarks/format-bench.lisp), whose second column
(values from 0.001 to 0.1) includes `~,2F` of values below 0.01; the 1e-6 to
1e-2 timing above was a one-off measurement.

### The compiler transform

`(format nil "~,2F" x)` with a constant control string that is exactly one `~F`
directive with constant parameters now compiles (a deftransform in
`src/compiler/srctran.lisp`) to `sb-format::format-fixed-string`, which builds
the result string directly, without a string output stream. `format-fixed-aux`
and it share `format-fixed-pieces`, the width, sign and optional-zero
logic. About 20 ns per call: `~,2F` 120 -> 100 ns, `~8,3F` 145 -> 120 ns.

The transform also covers single `~E`, `~G` and `~$` directives
(`format-exponential-string`, `format-general-string`,
`format-dollars-string`). Their finite-float code is written once with
`define-float-emitter`, which generates a stream version (the existing
behaviour) and a string version that collects the output in a 128-character
stack buffer; longer output is redone through the stream version, so both always
agree. `~G` chooses between fixed and exponential form in `format-general-plan`,
shared by both versions. Gains, compiled `format nil` against the same code
through a string stream: `~,3E` 180 -> 130 ns, `~$` 135 -> 100 ns, `~,2G` 200 ->
155 ns, `~G` 230 -> 205 ns.

Tests: [`transform.lisp`](tests/transform.lisp) (compiled against interpreted,
and that the transform fires). Benchmark:
[`format-bench.lisp`](benchmarks/format-bench.lisp), whose calls have constant
control strings, so they are compiled through the transform.

## Reading

### The fast path in the reader

`make-float` in `src/code/reader.lisp` first tries `make-float/fast`. It scans
the token (an optional sign, ASCII digits with at most one point, and an
optional exponent marker E, S, F, D or L with an optional sign and digits) into
a 64-bit significand W of at most 19 significant digits and a decimal exponent
Q. Anything else (more digits, the R marker, other float formats) returns NIL,
and the original exact rational code runs as before, so results and errors are
unchanged.

The conversion is fast_float's `compute_float`: W times a 128-bit approximation
of 5^Q, one 64x128-bit multiplication, then a shift and rounding. The second
half of the 128-bit power is only needed when the low bits that decide the
result are all ones. Exact halfway cases with an even lower neighbour round
down, which can only happen where 5^Q fits in 64 bits. Up to 19 digits the
result is always correctly rounded (Mushtak and Lemire, "Fast Number Parsing
Without Fallback"). Results that overflow or underflow to zero return NIL and
also go to the exact code, which signals the reader's error or returns zero.

The table of 5^Q for Q from -342 to 308 is computed at compile time from
integers only, as fast_float's `table_generation.py` does: rounded up for
negative Q, truncated for positive Q, normalized so the high bit is set. No
floating-point arithmetic happens while cross-compiling.

Tests: [`parse-float.lisp`](tests/parse-float.lisp) (fast path on and off),
[`single-roundtrip.lisp`](tests/single-roundtrip.lisp) (every single-float, and
random doubles, printed and read back). Benchmark:
[`read-bench.lisp`](benchmarks/read-bench.lisp).

### Build-host independence

SBCL can be built by another Lisp, and its CI checks that CLISP, CCL and CMUCL
produce exactly the same compiled code as SBCL itself. The first version had one
conversion function taking the float format as an argument, and hosts disagreed
on how far that constant argument was propagated, so the code differed. Now one
`macrolet` template generates `decimal-to-double-bits` and
`decimal-to-single-bits` with each format's constants written in
literally. `decimal-to-float`, which picks one of them, is deliberately not
inline, for the same reason: compiled once, it does not depend on whether a
caller's constant argument gets folded.

Checked by SBCL's own CI, which builds with several host Lisps and compares the
results; there is no test file for it here.

### Subnormals

For subnormal results the code first chose the exponent field with an `(if ... 0
1)` and then assembled the bits. That is not needed: the result's bits are the
rounded mantissa itself. Below 2^52 it is a subnormal; if rounding carried into
the smallest normal, it is exactly 2^52, whose set bit is that normal's exponent
field of 1. Removing the `if` also removed another place where hosts compiled
differently.

Tests: [`parse-float.lisp`](tests/parse-float.lisp) (subnormal and underflow
boundaries), [`single-roundtrip.lisp`](tests/single-roundtrip.lisp).

### `sb-ext:parse-float`

`(sb-ext:parse-float string &key (start 0) end junk-allowed)` returns `(values
float index)`, with the same argument handling, whitespace rules and errors as
`parse-integer`, but without `:radix`, since float syntax is decimal. It accepts
`[sign] digits [. digits] [marker [sign] digits]` with the reader's markers E,
S, F, D and L, plus plain integers ("12", "12.") as floats; the marker or
`*read-default-float-format*` decides the type.

`parse-float` scans the string itself, collecting up to 19 significant
digits. It then calls the same `decimal-to-float` as the reader. With more
digits, or when the fast path returns NIL, it builds the exact value as
MAKE-FLOAT does (the digits as an integer, scaled by a power of ten) and
converts that; a number too large for its format signals a `parse-error`, as the
reader does. On 32-bit platforms only the exact code is used. Since no reader,
readtable or string stream is involved, it is about 3.5 to 5 times faster than
`read-from-string` on the same strings ([readme.md](readme.md), "Results").

`with-array-data` leaves a `simple-string`, which may be a base string (one
byte per character) or a character string (four bytes, UTF-32), so a plain
`char` tests which one before every load. The body after the leading whitespace
is therefore compiled twice with `string-dispatch`, once for each kind, and the
type is tested once per call. Both kinds are common: `format nil`,
`prin1-to-string` and `princ-to-string` return base strings for ASCII text,
while `read-line` and string literals give character strings. Measured in the
built SBCL, with and without the dispatch, alternately: 17-digit numbers in
[`read-bench.lisp`](benchmarks/read-bench.lisp) (base strings) take 50 instead
of 60 ns, and the lines of [`real-data.lisp`](benchmarks/real-data.lisp)
(character strings, from `read-line`) 5-12% less. The digits need nothing
special: `reader.lisp` declares `digit-char-p` inline, and for ASCII it is a
subtraction and a compare; only above code 1632 does it look up other scripts'
digits. A version that also checked ASCII digits itself was no faster.
`parse-integer` gains nothing from the same dispatch:
[`parse-integer-bench.lisp`](benchmarks/parse-integer-bench.lisp).

Tests: [`parse-float-function.lisp`](tests/parse-float-function.lisp) (against
the reader, an exact reference, and `parse-integer`'s interface),
[`single-roundtrip.lisp`](tests/single-roundtrip.lisp),
[`third-party.lisp`](tests/third-party.lisp). Benchmarks:
[`read-bench.lisp`](benchmarks/read-bench.lisp),
[`third-party.lisp`](tests/third-party.lisp) (against the `parse-float` and
`parse-number` libraries).
