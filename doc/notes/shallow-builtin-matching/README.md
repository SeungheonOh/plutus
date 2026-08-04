# Shallow built-in `Match`: implementation, calibration, and comparison

Date: 2026-08-04

## Executive summary

This branch replaces the recursively nestable `DefaultBuiltinPattern` from
`sho/builtinMatching` with a genuinely shallow pattern language. Structural pattern positions
contain only `bind` or `wildcard`; nested data is deconstructed by a later `Match` in the selected
handler. This directly tests the compilation strategy suggested by
[Phillip Wadler in the CIP-0123 discussion](https://github.com/cardano-foundation/CIPs/pull/1236#issuecomment-5166926900): compare a nested matcher with ordinary compiler lowering to a
sequence of shallow matches.

The final CEK cost model has only two Match costs:

| Step | CPU | Memory | Meaning |
|---|---:|---:|---|
| `BMatch` | 27,493 | 200 | Enter `Match` and perform the first bounded root probe |
| `BMatchWork` | 19,134 | 100 | One conservative variable-work unit |

The CPU constants are the ceiling of the largest accepted one-sided 95% upper slope from three
complete calibration passes. Memory is a deliberately simple logical policy: retain the previous
high-memory Match envelope (200) and charge the standard CEK memory quantum (100) per variable
unit, so every additional bind is represented. Criterion measures time, not Plutus `ExMemory`, so
the memory numbers are policy values rather than a conversion from host heap bytes.

The comparison evaluated 27 nested `Data` shapes in 270 isolated CPU processes (27 cases × 2
implementations × 5 repeats), and also counted each case once with each implementation's production
cost model.

| Aggregate result | Shallow / nested | Interpretation |
|---|---:|---|
| CPU time, geometric mean | 1.052 | Shallow was 5.2% slower overall |
| Execution-budget CPU, geometric mean | 0.888 | Shallow used 11.2% less budget CPU overall |
| Execution-budget memory, geometric mean | 2.287 | Shallow used 2.29× logical budget memory |
| Cases with lower shallow wall time | 15 / 27 | The result depends strongly on depth and width |

Shallow matching won all nine depth-1 cases and all nine width-16 cases. It lost the narrow/deep
cases because lowering performs one `Match` per level (and one extra Pair `Match` at each map level),
whereas the nestable implementation walks the whole pattern under one AST `Match`. The widest cases
reverse that result: the shallow field loops are simpler enough to offset the additional Match
nodes.

## Provenance and isolation

- Base branch: `master` at `b9d726d7cc957fa154c6ba9f01959952887f1246`.
- Shallow branch: `sho/shallowBuiltinMatching` in
  `/home/sho/io/plutus/.worktrees/shallowBuiltinMatching`.
- Original nested branch: `sho/builtinMatching` at
  `20d7f06ed4dc5f29439b5b0d4b1ab8a62627f3b3`; it was read but not modified.
- Dedicated comparison branch: `sho/nestedMatchingComparison` in
  `/home/sho/io/plutus-nestedMatchingComparison`.
- For a fair current-master toolchain comparison, the nested implementation was ported unchanged in
  behavior to `d90030af8dee591a8855bbca1784f3c43ca582ef`, then the focused runner was added. The
  comparison branch ends at `febf147c42de548a5c312b69dbfe32d6436f2b8b`.
- No GitHub comment, review reply, issue update, push, or PR was made.

The final shallow tree deliberately does **not** contain the full Match conformance corpus or the
large granular Match test suite imported while studying the nested branch. Existing narrow cost
model tests and manual syntax/evaluation checks were used instead. The branch history is squashed
before handoff so those prohibited test additions are not part of the deliverable history either.

## Pattern language

### Nonrecursive representation

The important type split is:

```haskell
data DefaultPatternField
  = DefaultPatternFieldWildcard
  | DefaultPatternFieldBind

data DefaultPatternFieldEnd
  = DefaultPatternFieldsExact
  | DefaultPatternFieldsRest
```

`DefaultBuiltinPattern` remains capable of selecting a scalar value at the root, but every
structural constructor now contains only `DefaultPatternField`, never another
`DefaultBuiltinPattern`:

| Pattern | Accepted shallow payload |
|---|---|
| `(wildcard)` | Match any root value without binding |
| `(bind)` | Match and bind the root value |
| `(integer n)` | Exact `Int64` literal |
| `(bytestring #...)` | Exact bytes, charged in 8-byte chunks |
| `(bool b)` / `(unit)` | Exact scalar |
| `(list fields...)` | Immediate fields of a builtin list |
| `(pair left right)` | Exactly two immediate pair fields |
| `(data-constr tag fields...)` | Outer `Constr`, exact `Word64` tag, immediate `Data` fields |
| `(data-map fields...)` | Immediate map entries, each entry bound as a `Data × Data` pair |
| `(data-list fields...)` | Immediate `Data` list fields |
| `(data-i field)` | Immediate integer payload of `Data.I` |
| `(data-b field)` | Immediate bytes payload of `Data.B` |

Each `field` is exactly `(bind)` or `(wildcard)`. List-like patterns optionally accept one direct,
terminal `(rest)`, which ignores the unmatched suffix and does not bind it:

```text
(data-constr 0 (bind) (wildcard) (bind) (rest))
(list (bind) (bind) (wildcard))
(data-map (wildcard) (bind) (rest))
```

Pair, `data-i`, and `data-b` are fixed-width and do not accept `rest`. Exact sequence patterns
require the scrutinee to have exactly the declared number of fields. A rest pattern requires at
least the declared prefix and ignores the remaining suffix in constant time.

The parser therefore rejects both forms below by construction:

```text
(list (integer 1))       -- a nested pattern in a field position
(list (rest) (bind))     -- nonterminal rest
```

`Match` is gated at experimental UPLC version 1.2.0; version 1.1 remains the default released
version. Integer pattern literals are bounded to `Int64`, and `data-constr` tags to `Word64`.

### Pretty, hash, and Flat representation

- Pretty-printing emits the direct terminal syntax shown above.
- Structural hashes include the end mode, field count, and each field in serialization order.
- A field uses one Flat bit (`0 = wildcard`, `1 = bind`).
- Root pattern tags remain four bits: tags 0–12 are the 13 concrete root descriptors.
- Tag 13 is a `rest` prefix followed by one of the sequence descriptor tags 6, 8, 9, or 10.
- Tags 14 and 15 remain unavailable.

This encoding is for the experimental 1.2 design and intentionally differs from the earlier
nested experimental encoding: vectors serialize one-bit fields rather than recursively encoded
patterns.

## Matching semantics and CEK integration

`Match` evaluates the scrutinee, asks the universe matcher to select the first successful
alternative, and returns the handler plus captured constants in head-spine form. Captures are
accumulated in reverse while scanning and materialized once in left-to-right handler-application
order. Captures from a failed alternative are discarded before the next alternative.

The implementation is shallow throughout:

- there is no recursive pattern work stack;
- there is no nested-pattern propagation;
- there is no matcher backtracking stack beyond ordered alternatives;
- list-like values and vectors are streamed only across the immediate requested fields;
- `rest` never traverses the ignored suffix;
- nested deconstruction is represented by later UPLC `Match` nodes in handlers.

Both the production CEK and steppable CEK expose only `BMatch` and `BMatchWork`. A bulk step spender
routes variable work through the same bounded-slippage counters used by ordinary CEK steps. The
matcher is passed as a separate universe capability next to the existing builtin caser, and the
ledger/evaluation-context plumbing can independently enable or reject it by protocol version.

### Work formula

The fixed `BMatch` step covers entry and the first bounded root probe. Additional work is:

| Operation | `BMatchWork` units |
|---|---:|
| Alternative after the first | 1 |
| Root bind | 1 |
| Immediate wildcard field | 1 |
| Immediate bind field | 2 (one field + one capture) |
| ByteString literal | `ceil(pattern bytes / 8)` |
| First integer/bool/unit/wildcard exact probe | 0 |
| Ignored `rest` suffix | 0 |

A failed structural alternative conservatively prepays all fields and binds declared in its syntax,
even if the outer value has another type or too few fields. This is simple, deterministic, and
bounds all syntax-sized matcher work.

An independent review caught an important ordering problem before final calibration: the first
implementation folded across the field vector to count binds before calling the budget spender.
The final code uses two-phase precharge:

1. Compute the field base in O(1) with `Vector.length` (or the fixed scalar/byte length), then spend
   it.
2. Scan bind flags, now covered by phase 1, spend the bind extras, and only then inspect the
   scrutinee or materialize captures.

The totals did not change, but this ordering ensures an input-sized operation never occurs before
the work that bounds it has been charged.

## Granular costing calibration

### Workloads and exact validation

The calibration suite contains 14 paired families at scales 16, 64, 256, and 1024: 112 recipes in
total. A recipe is `Unit -> Term`; the suite never retains a prebuilt corpus of UPLC terms.

| Family | What it isolates |
|---|---|
| `entry-integer` | Fixed Match entry, paired against equivalent `Case` chains |
| `rejected-alternatives` | Linear failed-root dispatch after the first alternative |
| `list-fields` | Builtin list immediate field scan |
| `data-list-fields` | `Data.List` immediate field scan |
| `data-constr-fields` | `Data.Constr` immediate field scan |
| `data-map-fields` | `Data.Map` immediate entry scan |
| `root-capture-success` | Successful root capture and implicit handler lambda |
| `field-capture-success` | Successful field captures and implicit handler lambdas |
| `field-capture-abandoned` | Capture allocation discarded by an exact-arity failure |
| `rest-suffix` | Audit that ignored suffix length adds no work |
| `pair-bounded` | Repeated fixed-width pair probes |
| `data-i-bounded` | Repeated fixed-width `Data.I` probes |
| `data-b-bounded` | Repeated fixed-width `Data.B` probes |
| `bytestring-8-byte-chunks` | Exact ByteString equality per charged chunk |

Before Criterion starts, every recipe is run with unit CEK costs and checked for exact dynamic
`BMatch`, `BMatchWork`, `BCase`, and `BLamAbs` counts. All 112 passed after the two-phase precharge
fix. The successful-capture pairs subtract the known `BLamAbs` model cost; implicit capture
application uses the CEK's direct head-spine path and does not introduce a `BApply` step.

Criterion uses one fully forced term in `env` for the current benchmark. The analysis takes paired
work-minus-control means, subtracts known Case/LamAbs costs, fits ordinary least squares against
the exact dynamic target-step delta, and calculates a one-sided 95% Student-t upper slope. A fit is
accepted only for the intended target, with nonnegative slope and upper bound and R² ≥ 0.95.
`rest-suffix` is audit-only. Each run recommends the ceiling of the largest accepted upper slope.
The installed constant is the maximum recommendation across the three final runs.

### Measurement environment

- CPU: AMD Ryzen 9 7950X, 16 cores / 32 threads.
- Affinity: logical CPU 15 only; its SMT sibling is CPU 31.
- Driver/governor/EPP: `amd-pstate-epp`, `powersave`, `balance_performance`; boost enabled.
- Frequency range reported by the host: 425.292–5883.197 MHz.
- OS: Linux 7.0.0-27-generic x86_64.
- GHC 9.6.7, cabal-install 3.12.1.0, Criterion 1.6.5.0, `-O1`.
- Criterion: `-L 1 --resamples 1000`, one capability (`-threaded -N1`).

### Final run results

| Run | Fixed slope | Fixed 95% upper | Work-limiting family | Work slope | Work 95% upper | Elapsed | Max RSS |
|---:|---:|---:|---|---:|---:|---:|---:|
| 1 | 26,603.06 | 27,492.55 | rejected alternatives | 18,391.83 | 19,133.33 | 166.85 s | 52,528 KiB |
| 2 | 26,848.09 | 27,125.92 | rejected alternatives | 17,025.41 | 17,309.93 | 166.48 s | 52,444 KiB |
| 3 | 27,053.02 | 27,189.10 | rejected alternatives | 16,886.80 | 17,222.33 | 166.71 s | 52,484 KiB |

The fixed-entry R² values were 0.999738, 0.999975, and 0.999994. The limiting failed-alternative
R² values were 0.999619, 0.999934, and 0.999907.

The complete family fits are in the three `calibration-fit-run-*.json` artifacts. The most useful
cross-run summary is:

| Family | Target | 95% upper, runs 1 / 2 / 3 (ps) | Minimum R² | Largest accepted upper |
|---|---|---:|---:|---:|
| entry integer | Match | 27,492.55 / 27,125.92 / 27,189.10 | 0.999738 | 27,492.55 |
| rejected alternatives | Work | 19,133.33 / 17,309.93 / 17,222.33 | 0.999619 | 19,133.33 |
| list fields | Work | 3,724.75 / 3,750.86 / 3,729.48 | 0.999958 | 3,750.86 |
| data-list fields | Work | 3,719.60 / 3,755.24 / 3,732.76 | 0.999943 | 3,755.24 |
| data-constr fields | Work | 3,732.81 / 3,756.17 / 3,732.12 | 0.999931 | 3,756.17 |
| data-map fields | Work | 3,727.31 / 3,736.85 / 3,719.07 | 0.999944 | 3,736.85 |
| abandoned field captures | Work | 1,858.90 / 1,876.90 / 1,868.19 | 0.999873 | 1,876.90 |
| pair bounded | Work | 4,298.42 / 4,783.92 / 5,821.61 | 0.995297 | 5,821.61 |
| data-i bounded | Work | 8,087.02 / 6,536.02 / 8,219.31 | 0.996048 | 8,219.31 |
| data-b bounded | Work | 8,958.58 / 11,607.65 / 8,292.01 | 0.965291 | 11,607.65 |
| ByteString chunks | Work | 407.61 / 428.03 / 412.10 | 0.998638 | 428.03 |
| root capture success | Work | negative in all runs | 0.997290 | rejected |
| field capture success | Work | negative in all runs | 0.853681 | rejected |
| rest suffix | Audit | 4.42 / 2.84 / 1.75 | audit-only | not selectable |

Successful-capture residuals are negative after subtracting the already charged 16,000-CPU
`BLamAbs` step per capture, so they cannot identify a positive matcher quantum and are correctly
excluded. The abandoned-capture family isolates capture retention without handler evaluation and
remains positive and highly linear. The rest-suffix slope is statistically negligible relative to
the selected quantum and never participates in cost selection.

The final CPU values are therefore:

```text
cekMatchCost.exBudgetCPU     = ceil(27492.5467) = 27493
cekMatchWorkCost.exBudgetCPU = ceil(19133.3289) = 19134
```

All five A–E CEK JSON files contain the same two Match constants.

### Rejected pilot data and benchmark validity fixes

Two pilot passes ran before the independent review found the pre-spend field fold. Their provisional
recommendations were 27,966/14,305 and 28,565/16,199 (fixed/work); they are excluded because they
do not measure the final precharge ordering. A third pilot was interrupted immediately. None of the
pilot CSVs is in the tracked results.

An earlier max-case smoke also exposed a Haskell `Strict` pitfall in the comparison term builder:
a recursive `nextValue` binding outside the positive-depth branch was evaluated at the terminal
guard. Three budget smokes had been launched in parallel, making the bug show up as rapidly growing
RSS. Those processes were terminated and produced no accepted result. The recursion now lives only
inside the positive-depth branch, with a source comment explaining why. After the fix, sequential
`alternating-d16-w16` budget mode completed in about 0.010 s with 55,024 bytes maximum residency
(6 MiB RTS total), and list mode had the same baseline while constructing no term.

## Nested-versus-shallow benchmark design

The 27 cases are the Cartesian product of:

- family: repeated `Constr`, repeated `List`, or `Constr/List/Map` alternating by level;
- depth: 1, 4, or 16;
- width: 1, 4, or 16 immediate fields/entries per level.

The continuation is the last field; other fields are `Data.I 0`. The terminal value is `Data.I 42`,
and every run verifies the final integer result is exactly 42.

The nested implementation constructs one recursively nested pattern under one UPLC `Match`. The
shallow implementation emits one structural `Match` per level and a terminal `data-i` Match. At a
map level, shallow `data-map ... (bind)` captures the selected entry pair and a second shallow
`pair (wildcard) (bind)` Match extracts its value. This is the direct shallow lowering of the same
deconstruction, not a different input.

### Memory and process discipline

- Both runners retain only 27 small `Unit -> Term` recipes.
- List mode prints metadata without calling any recipe.
- Case selection happens before `buildSelected`.
- CPU mode constructs and fully forces exactly one selected term in Criterion `env`.
- Budget mode constructs exactly one selected term.
- No benchmark serializes or deserializes UPLC, so there is no decoded-term corpus or Flat decoding
  pressure in the timed path.
- Every CPU row came from a fresh OS process running one case and one implementation.
- Only one such process ran at a time, pinned to logical CPU 15 with `-N1`.
- Both executables use identical `-threaded -rtsopts -with-rtsopts=-N1` component flags.
- Five repeats were collected. Odd repeats ran shallow then nested; even repeats reversed the order.
- Criterion used `-L 1 --resamples 1000`; the complete 270-process matrix took 406 seconds.
- Per-case CPU is the median of the five Criterion `Mean` values. Cross-case ratios use geometric
  means.

Execution budgets are deterministic production-parameter runs. The shared CSV schema reports total
CPU/memory plus `BMatch`/`BMatchWork` for shallow and the older
`BMatch`/`BPattern`/`BStructural`/`BMatchNext` counts for nested.

## Comparison results

All ratios below are shallow divided by nested; values below 1 favor shallow.

### By family

| Family | Shallow faster | Time S/N | Shallow speedup | Budget CPU S/N | Budget memory S/N |
|---|---:|---:|---:|---:|---:|
| `alternating` | 5/9 | 1.067 | 0.937× | 0.914 | 2.354 |
| `constr` | 5/9 | 1.043 | 0.959× | 0.875 | 2.254 |
| `list` | 5/9 | 1.046 | 0.956× | 0.875 | 2.254 |

### By depth

| Depth | Shallow faster | Time S/N | Shallow speedup | Budget CPU S/N | Budget memory S/N |
|---:|---:|---:|---:|---:|---:|
| 1 | 9/9 | 0.907 | 1.102× | 0.845 | 1.532 |
| 4 | 3/9 | 1.067 | 0.938× | 0.899 | 2.384 |
| 16 | 3/9 | 1.204 | 0.831× | 0.920 | 3.273 |

### By width

| Width | Shallow faster | Time S/N | Shallow speedup | Budget CPU S/N | Budget memory S/N |
|---:|---:|---:|---:|---:|---:|
| 1 | 3/9 | 1.209 | 0.827× | 0.740 | 2.804 |
| 4 | 3/9 | 1.093 | 0.915× | 0.860 | 2.271 |
| 16 | 9/9 | 0.882 | 1.134× | 1.099 | 1.879 |

### Every case

| Case | Shallow CPU (µs) | Nested CPU (µs) | Time S/N | Budget CPU S/N | Budget memory S/N |
|---|---:|---:|---:|---:|---:|
| `alternating-d1-w1` | 0.349 | 0.369 | 0.947 | 0.725 | 1.496 |
| `alternating-d1-w4` | 0.362 | 0.390 | 0.926 | 0.813 | 1.523 |
| `alternating-d1-w16` | 0.396 | 0.469 | 0.843 | 1.024 | 1.580 |
| `alternating-d4-w1` | 0.574 | 0.467 | 1.229 | 0.793 | 3.044 |
| `alternating-d4-w4` | 0.636 | 0.571 | 1.114 | 0.906 | 2.549 |
| `alternating-d4-w16` | 0.802 | 0.884 | 0.907 | 1.132 | 2.028 |
| `alternating-d16-w1` | 1.547 | 1.003 | 1.543 | 0.822 | 5.224 |
| `alternating-d16-w4` | 1.778 | 1.387 | 1.282 | 0.942 | 3.375 |
| `alternating-d16-w16` | 2.669 | 2.703 | 0.987 | 1.167 | 2.221 |
| `constr-d1-w1` | 0.349 | 0.369 | 0.946 | 0.725 | 1.496 |
| `constr-d1-w4` | 0.362 | 0.390 | 0.928 | 0.813 | 1.523 |
| `constr-d1-w16` | 0.396 | 0.468 | 0.845 | 1.024 | 1.580 |
| `constr-d4-w1` | 0.545 | 0.442 | 1.232 | 0.720 | 2.771 |
| `constr-d4-w4` | 0.589 | 0.523 | 1.127 | 0.857 | 2.347 |
| `constr-d4-w16` | 0.733 | 0.836 | 0.877 | 1.116 | 1.935 |
| `constr-d16-w1` | 1.223 | 0.830 | 1.473 | 0.718 | 5.121 |
| `constr-d16-w4` | 1.408 | 1.130 | 1.246 | 0.877 | 3.095 |
| `constr-d16-w16` | 2.165 | 2.454 | 0.882 | 1.149 | 2.094 |
| `list-d1-w1` | 0.346 | 0.363 | 0.954 | 0.725 | 1.496 |
| `list-d1-w4` | 0.358 | 0.383 | 0.933 | 0.813 | 1.523 |
| `list-d1-w16` | 0.393 | 0.462 | 0.851 | 1.024 | 1.580 |
| `list-d4-w1` | 0.517 | 0.425 | 1.218 | 0.720 | 2.771 |
| `list-d4-w4` | 0.564 | 0.505 | 1.116 | 0.857 | 2.347 |
| `list-d4-w16` | 0.710 | 0.816 | 0.870 | 1.116 | 1.935 |
| `list-d16-w1` | 1.179 | 0.766 | 1.538 | 0.718 | 5.121 |
| `list-d16-w4` | 1.323 | 1.069 | 1.237 | 0.877 | 3.095 |
| `list-d16-w16` | 2.116 | 2.401 | 0.881 | 1.149 | 2.094 |

The best shallow wall-time ratio is 0.843 (`alternating-d1-w16`, 15.7% less time). The worst is
1.543 (`alternating-d16-w1`, 54.3% more time). The shallow budget-CPU ratio ranges from 0.718
(`constr-d16-w1`) to 1.167 (`alternating-d16-w16`). Logical budget-memory ratios range from 1.496
to 5.224.

The deepest/widest exact budgets illustrate the tradeoff:

| Case | Implementation | Budget CPU | Budget memory | Match | Work/pattern/structural |
|---|---|---:|---:|---:|---|
| constr/list d16 w16 | shallow | 6,270,197 | 34,400 | 17 | 274 work |
| constr/list d16 w16 | nested | 5,457,916 | 16,431 | 2 | 211 pattern, 257 structural |
| alternating d16 w16 | shallow | 6,854,672 | 37,900 | 22 | 289 work |
| alternating d16 w16 | nested | 5,872,676 | 17,061 | 2 | 241 pattern, 267 structural |

The CPU-time result and execution-budget result answer different questions. Wall time measures these
two concrete implementations on one host. Budget CPU applies deliberately conservative calibrated
quanta; shallow's single work quantum is set by failed-alternative dispatch, so it overprices its
much cheaper field scans. Budget memory counts repeated shallow Match nodes and every work unit at
100, which is why it is higher despite bounded host residency.

## Validation performed

Focused builds and existing tests completed successfully:

- `lib:plutus-core`;
- `lib:untyped-plutus-core-testlib`;
- `lib:plutus-conformance`;
- `lib:plutus-ledger-api-testlib`;
- `test:plutus-core-test`;
- `test:untyped-plutus-core-test`;
- `exe:uplc` (including the 305-module metatheory dependency);
- shallow `bench:matching-costing` and `bench:matching-comparison`;
- nested dedicated `bench:matching-comparison`.

Existing focused results included 21/21 cost-model-interface checks, 5/5 machine-cost-safety checks,
2/2 number-of-step-counter checks, 878 untyped tests, and 2,336 plutus-core tests. These existing
suites do not provide a retained automated Match suite; that gap is intentional under the request
not to add full conformance or granular test suites.

Manual UPLC checks covered:

- list bind/wildcard/rest capture order;
- sequential outer `data-constr` then `data-list` deconstruction;
- exact-arity failure discarding captures and taking fallback;
- text → Flat → text round-trip for shallow structural descriptors;
- parser rejection of nested fields and nonterminal rest;
- first integer alternative tallying `Match=1`, `MatchWork=0`;
- list wildcard+bind+rest tallying `Match=1`, `MatchWork=3`;
- post-review three-field/two-bind tallying `MatchWork=5`;
- a failed three-bind alternative followed by a successful two-bind alternative tallying
  `MatchWork=11` with correct capture cleanup;
- production and steppable CEK termination/routing.

All 27 budget cases returned 42 under both implementations. `git diff --check` passed during the
implementation and benchmark handoffs and is rerun before final commit.

## Reproduction

Build the shallow components once:

```console
nix develop --command cabal build \
  plutus-benchmark:bench:matching-costing \
  plutus-benchmark:bench:matching-comparison
```

Generate metadata, collect one calibration pass, and fit it:

```console
costing=$(nix develop --command cabal list-bin \
  plutus-benchmark:bench:matching-costing | tail -n 1)

MATCHING_COSTING_MODE=metadata "$costing" > calibration-metadata.csv
taskset -c 15 "$costing" -L 1 --resamples 1000 \
  --csv calibration-run.csv +RTS -N1 -RTS
python3 plutus-benchmark/matching/costing/analyse.py \
  calibration-metadata.csv calibration-run.csv \
  --machine-costs plutus-core/cost-model/data/cekMachineCostsE.json
```

Run one CPU comparison case in its own process:

```console
comparison=$(nix develop --command cabal list-bin \
  plutus-benchmark:bench:matching-comparison | tail -n 1)

MATCHING_BENCH_MODE=cpu \
MATCHING_BENCH_CASE=alternating-d16-w16 \
taskset -c 15 "$comparison" -L 1 --resamples 1000 \
  --csv one-case.csv +RTS -N1 -RTS
```

Run the same selected case deterministically for budget output:

```console
MATCHING_BENCH_MODE=budget \
MATCHING_BENCH_CASE=alternating-d16-w16 \
taskset -c 15 "$comparison" +RTS -N1 -RTS
```

Aggregate the tracked raw comparison data:

```console
python3 plutus-benchmark/matching/comparison/analyse.py \
  doc/notes/shallow-builtin-matching/results/comparison-cpu-raw.csv \
  doc/notes/shallow-builtin-matching/results/comparison-budget.csv \
  --cases-out comparison-cases.csv > comparison-summary.json
```

The original run used the shallow executable from the requested worktree and the nested executable
from the dedicated comparison worktree. The 270-process orchestration alternated implementation
order and never ran two benchmark processes concurrently.

## Artifacts

- [Calibration metadata](results/calibration-metadata.csv)
- [Calibration run 1](results/calibration-run-1.csv) and
  [fit 1](results/calibration-fit-run-1.json)
- [Calibration run 2](results/calibration-run-2.csv) and
  [fit 2](results/calibration-fit-run-2.json)
- [Calibration run 3](results/calibration-run-3.csv) and
  [fit 3](results/calibration-fit-run-3.json)
- [All 270 raw CPU rows](results/comparison-cpu-raw.csv)
- [All 54 deterministic budget rows](results/comparison-budget.csv)
- [Per-case medians and ratios](results/comparison-cases.csv)
- [Aggregate comparison JSON](results/comparison-summary.json)
- [SHA-256 checksums](results/SHA256SUMS)

The raw CPU CSV retains Criterion mean, lower/upper mean, standard deviation, lower/upper standard
deviation, repeat number, and pair order for every process.

## Limitations

- Match and UPLC 1.2 remain experimental and are not the default released language version or a
  ledger-activated feature.
- CPU constants and wall-time comparisons are host/toolchain specific; the complete raw data makes
  recalibration on the production reference machine straightforward.
- The one work quantum is intentionally conservative. Failed-alternative dispatch determines it,
  while field and byte work are substantially cheaper.
- `ExMemory` values are simple logical policy constants, not inferred from Criterion wall time or
  host RSS.
- The comparison uses controlled synthetic nested `Data` shapes. It isolates deconstruction but is
  not an application-level workload distribution.
- No new full conformance suite or exhaustive/granular Match regression suite was added, by
  explicit request.
