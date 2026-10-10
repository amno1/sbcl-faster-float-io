# Faster integer reading and printing

This continues the float work in [`readme.md`](readme.md) with two smaller
changes for integers, each on its own branch:

- **Reading**: a fast path in the reader's `read-token` that recognizes
  integers and floats directly in the string being read. Branch
  [`sbcl-read-fast`](https://github.com/amno1/sbcl/tree/sbcl-read-fast), based
  on `sbcl-parse-float`, because it converts floats with Eisel-Lemire.

- **Printing**: base-10 printing of word-sized integers without a division per
  digit. Branch
  [`sbcl-int-print`](https://github.com/amno1/sbcl/tree/sbcl-int-print), based
  on `sbcl-zmij`, because it writes the digits with zmij's SSE2 digit routine.

[`sb-simd-512`](https://github.com/amno1/sbcl/tree/sb-simd-512) has both, on
top of the float work.

All numbers below were measured on 2026-10-10 on x86-64 (my laptop, on mains
power), in nanoseconds per call. "Upstream" is plain SBCL at commit
[`c2aca591d`](https://github.com/sbcl/sbcl/commit/c2aca591d), the same base as
the float results. The builds were run alternately, and each figure is the best
of its runs. The scripts are described in [`tests.md`](tests.md), and the full
output is in [`results`](results).

## In short

**Reading** an integer of up to 18 digits with `read-from-string` is about
**2.2x faster** (190 ns to 85 ns for 18 digits), and short integers 1.4x.
Floats read through the new fast path are another **1.5-2x faster** on top of
Eisel-Lemire, 1.4-1.9x on real-world data. Together with Eisel-Lemire, reading
the `canada` coordinates is more than three times faster than in upstream.

**Printing** an 18-digit integer is **1.4-2x faster**: 1.4x with
`prin1-to-string`, 2x with `prin1` to a stream, 1.6x with `~D`. Short
integers and bignums print as fast as before.

**Results are unchanged**: the same objects are read and the same characters
printed.

Both changes are for **64-bit platforms**; 32-bit platforms keep the original
code.

## Reading: a fast path in `read-token`

### Where the time went

To read an 18-digit integer, `read-from-string` took 190 ns, while
`parse-integer` turns the same 18 digits into a number in 40 ns. A profile
with `sb-sprof`
([`profile-reader.lisp`](benchmarks/profile-reader.lisp), output in
[`log-profile-reader.txt`](results/log-profile-reader.txt)) shows why:

| where the time goes                                          | share |
|--------------------------------------------------------------|------:|
| `read-token`, the reader's character-by-character token scan |   43% |
| `make-integer`, building the integer from the token          |   19% |
| `base-char-in`, one stream call per character                |   18% |
| the rest of the reader                                       |   20% |

Building the integer is only a fifth of the time, and `make-integer` already
works in word-sized chunks of 18 digits. Most of the time goes to *finding* the
token: for every character, a call through the stream, a readtable lookup, a
copy into the token buffer and a step of the number-syntax state machine.
`make-integer` then reads the digits a second time from that buffer.

So a faster digit conversion (SWAR or SIMD) could gain at most that fifth. The
token scan itself had to get cheaper.

### What the fast path does

`read-token` now first calls `read-number/fast` when it reads from a string
(`read-from-string`, `with-input-from-string`) and `*read-base*` is 10. It
looks at the string itself, without a stream call or a buffer per character,
for a token of the form

```
[sign] digits [. digits] [marker [sign] digits]
```

that ends at the end of the string or at a delimiter. If it finds an integer of
at most 18 significant digits, it returns it; if it finds a float, it converts
it with Eisel-Lemire. In every other case it consumes nothing, and `read-token`
reads the token exactly as before.

Two properties make that safe:

**If it gives up, the stream is untouched.** A string input stream holds the
string, the current position `index` and the end `limit`. The fast path does
not call `read-char`: it reads characters from the string with its own copy of
the position, and sets `index` once, after the token, only when it succeeds.
It also checks that the first character, which the reader has already read, is
the one just before `index`; if not, it gives up rather than guess.

**If it succeeds, it decides as the reader would.** The reader classifies a
character in two steps: its *syntax type*, which belongs to the readtable and
can be changed (whitespace, terminating macro, escape, constituent), and, for
constituents, its *trait* (digit, sign, point, exponent marker), which in SBCL
comes from a fixed table. The fast path requires every character of the token
to have constituent syntax in the current readtable, and the token to end at
the end of the string or at a character whose syntax is whitespace or a
terminating macro, the same delimiter test `read-token` uses. Its traits then
follow from the character itself. So a modified readtable gives the same
result as with the normal reader: if `5` is made whitespace, `"15"` reads as
`1` with the position at the `5`, which is what the reader does too.

Within base 10 it follows the reader's number syntax: `123.` with a trailing
point is a decimal integer; a float needs a fraction or an exponent; `E`
follows `*read-default-float-format*`, `S` and `F` give single-floats, `D` and
`L` doubles. Other bases are left alone: in base 16, `1e5` is an integer.

It gives up, leaving the token to `read-token`:

- on anything that is not a number token: a letter as in `12abc`, `/` as in
  `1/2`, an escape, a package marker, a non-terminating macro character such
  as `#`;
- on integers of more than 18 significant digits, which may need a bignum;
- on floats of more than 19 significant digits, beyond what Eisel-Lemire is
  proven for, and on floats it does not convert: overflow, underflow to zero,
  very large exponents;
- on the `R` marker, for exact rationals.

`*read-suppress*` is checked before the fast path, as before.

### Results

**Integers**, `read-from-string`, upstream against the fast path
([log](results/log-int-read-bench.txt)):

| token                   | upstream | fast path | faster |
|-------------------------|---------:|----------:|-------:|
| integer, 18 digits      |      190 |        85 |   2.2x |
| integer, 1-5 digits     |       85 |        60 |   1.4x |
| symbol `X` + 18 digits  |      495 |       480 |   same |
| symbol `X` + 1-5 digits |      335 |       375 |   same |

The symbols are the control: the fast path gives up on them after one
character. Their times vary by up to 50 ns from run to run, because reading a
symbol interns it, so these differences are noise.

As a note, the same build varies by 100-150 ns from round to round, because
reading a symbol interns it. Taking the best round, as the table does, only
shows which build got lucky. A 40 ns gap means nothing at that spread.

**Floats**, `read-from-string`, against `sbcl-parse-float`, which already
converts floats with Eisel-Lemire, but only after the full token scan. This
isolates what the fast path itself adds
([log](results/log-read-fast-floats.txt)):

| token                          | `sbcl-parse-float` | fast path | faster |
|--------------------------------|-------------------:|----------:|-------:|
| short (`1.5`, `12.25`)         |                 90 |        60 |   1.5x |
| 17 digits, ordinary            |                180 |       100 |   1.8x |
| 17 digits, exponent up to ±300 |                200 |       100 |   2.0x |
| single-floats                  |                140 |        90 |   1.6x |
| integer, 16 digits             |                170 |        80 |   2.1x |

**Real-world data**, reading each line of the
[float-data](https://github.com/fastfloat/float-data) files with
`read-from-string`, again against `sbcl-parse-float`, best of two runs per
build ([log](results/log-read-fast-real-data.txt)):

| file                      | `sbcl-parse-float` | fast path | faster |
|---------------------------|-------------------:|----------:|-------:|
| `bitcoin`                 |                132 |        79 |   1.7x |
| `canada`                  |                171 |        93 |   1.8x |
| `gaia`                    |                180 |       101 |   1.8x |
| `hellfloat64`             |                204 |       110 |   1.9x |
| `marine_ik`               |                104 |        70 |   1.5x |
| `mesh`                    |                106 |        69 |   1.5x |
| `mobilenetv3_large`       |                130 |        83 |   1.6x |
| `noaa_gfs_1p00`           |                119 |        75 |   1.6x |
| `noaa_global_hourly_2023` |                101 |        74 |   1.4x |
| `numbers`                 |                142 |        85 |   1.7x |

Together with Eisel-Lemire, reading the `canada` coordinates is now more than
three times faster than in upstream (315 ns there). `sb-ext:parse-float`, which
skips the reader altogether, measured the same on both builds for every file
(within 1 ns), which confirms that the two builds ran under the same
conditions.

What is left is mostly the reader's fixed cost: creating the string stream, the
call through `read` and the readtable dispatch take about as long as the fast
path's scan and conversion of 18 digits.

### When the fast path gives up

For tokens it does not handle, the fast path scans part of the token, gives up,
and `read-token` then reads the whole token as before, so that work is wasted.
[`fast-path-misses.lisp`](benchmarks/fast-path-misses.lisp) measures the cost:
the same strings read with the fast path on and off, alternately in one process
([log](results/log-fast-path-misses.txt)):

| token                            | where it gives up | fast path off |    on |     cost |
|----------------------------------|-------------------|--------------:|------:|---------:|
| symbol, letter first (`foo123`)  | first character   |           170 |   160 |     none |
| symbol, one digit first (`1abc`) | after 1 digit     |            90 |    90 |     none |
| ratio (`123456/789`)             | at the `/`        |           140 |   150 |      +10 |
| symbol, 18 digits first          | after 18 digits   |           500 |   530 |      +30 |
| integer, 25 digits (a bignum)    | at the 20th digit |           220 |   270 |      +50 |
| float, 25 significant digits     | at the 20th digit |         1,380 | 1,460 | see text |
| *hit:* integer, 18 digits        |                   |           170 |    60 |     -110 |
| *hit:* float, `1.5`              |                   |            70 |    40 |      -30 |

A miss costs the scan up to the point where the fast path gives up: nothing for
a symbol that starts with a letter, about 40-50 ns in the worst cases, a token
that looks like a number for 18 or 20 digits. Measured directly, giving up on
the 25-digit float costs the same as on the 25-digit integer (about 40 ns); the
larger difference in its row is noise in the 1,400 ns exact conversion that
follows.

The longer a symbol's name looks like a number, the more the miss costs. The
most expensive realistic case is a name that starts with 18 or 19 digits, such
as `123456789012345678abc`: the fast path scans all the digits before it gives
up, which costs about 30 ns (the "18 digits first" row above).

So the fast path pays off as soon as about one token in three that starts like
a number is one: a hit saves 30-110 ns, the worst miss costs 40-50.

This measurement found a real cost at first: giving up inside the digit loop, a
local function, was a non-local exit, and a miss on a 25-digit integer cost 120
ns. Declaring the loop inline made giving up a plain jump: the miss now costs 50
ns, and hits got 10 ns faster.

### Correctness

The fast path must give exactly what the normal reader gives: the same object,
the same stream position afterwards, and the same error when there is one.
[`read-fast.lisp`](tests/read-fast.lisp) checks this directly. It reads 880,830
strings twice, once with the fast path and once without, and compares the
results; there were no differences.

The strings are random integers and floats and their edge cases, plus tokens the
fast path must leave alone: symbols, ratios, escapes, package prefixes, `#x1F`,
`1r5` and the like. They also cover several objects in one string,
`read-preserving-whitespace`, both default float formats, `*read-base*` 16,
`*read-suppress*`, and a readtable in which a digit is whitespace. A smaller
version of the same comparison is committed in the branch as
`tests/read-number.pure.lisp`.

The branch also passes SBCL's own test suite. The float tests were run on it
too, all without failures: Nigel Tao's parse-number test data
([`supplemental.lisp`](tests/supplemental.lisp)), 19,960,008 checks; float
reading against the exact code
([`parse-float.lisp`](tests/parse-float.lisp)), 10,006,588 strings; and every
value of the float-data files, printed and read back
([`real-data.lisp`](benchmarks/real-data.lisp)). The output is in
[`log-int-tests.txt`](results/log-int-tests.txt) and
[`log-read-fast-real-data.txt`](results/log-read-fast-real-data.txt).

`parse-float.lisp` reads each string through the reader with the fast path on,
and compares the float, bit for bit, with the exact code's. Its log says "0
through the fast path" because that counter only counts the older Eisel-Lemire
entry point, `make-float/fast`, and the new fast path now converts those floats
before it is reached.

### Integers without Eisel-Lemire

The integer part of the fast path uses nothing from the float work: the digits
are accumulated in one word and the sign applied. Only float tokens call
`decimal-to-float`. On plain upstream SBCL, the fast path could give up on float
tokens and leave them to the normal reader. That would make an integers-only
version, the 2.2x for 18-digit integers, independent of the Eisel-Lemire
patches.

## Printing: base-10 words without a division per digit

### Where the time went

[`profile-printer.lisp`](benchmarks/profile-printer.lisp) on upstream
([log](results/log-profile-printer.txt)): printing an 18-digit integer with
`prin1-to-string` spends two thirds of its time in the digit loop of
`%output-integer-in-base`, which divides by the base once per digit. For words,
the base is a variable there, so every division is a hardware divide. The string
stream takes about a tenth.

### The change

`%output-word-in-base-10` prints a word in base 10 without a division per
digit. It splits the number into `top * 10^16 + hi * 10^8 + lo` (the divisions
by constants compile to multiplications), writes `hi` and `lo` as 16 digits at
once with zmij's `%zmij-store-digits` (an SSE2 VOP on x86-64), and takes the
number of leading zeros from that routine's mask of nonzero digits. `top`, at
most four digits, goes in front. `%output-integer-in-base` uses it for words in
base 10 on 64-bit platforms; other bases, bignums and 32-bit platforms keep the
old loop.

### Results

`sbcl-zmij`, the branch's base, against `sbcl-int-print`, 18-digit integers
([log](results/log-int-print-bench.txt)):

| 18 digits            | before | after | faster |
|----------------------|-------:|------:|-------:|
| `prin1-to-string`    |     65 |    45 |   1.4x |
| `prin1` to a stream  |     50 |    25 |   2.0x |
| `(format nil "~D")`  |     80 |    50 |   1.6x |
| the digit loop alone |     35 |    15 |   2.3x |

Integers of 1-5 digits print as fast as before (their few divisions were
cheap), and so do bignums.

**Bignums: tried and dropped.** Bignums are printed in chunks of 19 digits, each
with the per-digit loop, so the same change looked promising there. It turned
out slower: 600-digit bignums took 2,400 ns instead of 1,800. The bignum code is
compiled separately for base 10 (`cond-dispatch`), so its divisions by 10 were
already multiplications; the change only added a function call and a buffer per
chunk. Integers that fit in a machine word (all fixnums, and anything below
2^64) are printed by a separate loop that had no base-10 version: it divided by
the base as a variable, a hardware divide for every digit. That is where the
gain comes from.

### A bug found along the way

Printing `most-negative-fixnum` in base 2 or 4 with `prin1-to-string` signals an
internal error ("Should not happen") in SBCL 2.6.9 and upstream master:

```lisp
(let ((*print-base* 2)) (prin1-to-string most-negative-fixnum))
```

`prin1-to-string` sizes its string with `approx-chars-in-repr`, which assumes a
fixnum has at most `n-positive-fixnum-bits` (62) bits. The magnitude of
`most-negative-fixnum`, 2^62, has 63. Only bases 2 and 4 fail: 62 bits divide
evenly into 1 and 2 bits per character, so the estimate has no spare character,
while the other bases round their bits per character down and leave
room. Printing to a stream was never affected, because the stream grows as
needed; only `prin1-to-string` and its relatives write into a string of the
estimated size. The code has been there since 2017, when `prin1-to-string` of
integers started writing into a preallocated string.

The fix uses `n-fixnum-bits` instead, with a regression test in
`tests/print.impure.lisp`. It was sent upstream as its own patch, and is a
separate commit in `sbcl-int-print`.

### Correctness

[`int-print.lisp`](tests/int-print.lisp) compares 3,365,968 printed integers
with a plain divide-by-10 reference: powers of ten up to 10^80 and their
neighbours, the fixnum and word limits, random words of every length, bignums
whose 19-digit chunks are zero or start with zeros, and random bignums, all with
both signs, through eight ways of printing (`prin1-to-string`,
`princ-to-string`, `prin1` to a stream, `~D`, `~:D`, `~10D`, `~@D` and
`*print-radix*`). There were no failures.

The branch adds `tests/integer-print.pure.lisp`, which checks base 10 and bases
2, 8, 9, 11, 16 and 36 against a reference, and passes SBCL's own test suite
([log](results/log-int-tests.txt)).

### A possible small saving

Not worth doing for now. For integers, `prin1-to-string` (`stringify-object`)
wraps its result string in a `finite-base-string-output-stream`. The digits are
written to a scratch buffer first, then copied into the string through the
stream. Writing the digits straight into a string of exactly the right size, as
the float patches do, would skip the stream, the copy and the indirect call.
Both the stream and the scratch buffer are on the stack, and the result string
is needed either way, so heap allocation would not change. The profile puts this
at about a tenth of the 45 ns for 18 digits, so maybe 5 ns.
