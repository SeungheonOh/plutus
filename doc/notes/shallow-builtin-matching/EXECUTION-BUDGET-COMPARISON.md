# Shallow versus nestable `Match`: execution-budget comparison

Date: 2026-08-04

## Scope

This document compares the execution budgets of the shallow matcher on
`sho/shallowBuiltinMatching` with the recursively nestable matcher preserved on
`sho/nestedMatchingComparison`. It uses only the already-recorded deterministic CEK counters and
budgets from the original 27-case comparison. No CPU or wall-time benchmark was rerun.

The shallow CPU prices used here are the revised prices installed by this branch:

| Implementation | CEK category | CPU | Memory |
|---|---|---:|---:|
| Shallow | `BMatch` | 27,190 | 200 |
| Shallow | `BMatchWork` | 17,310 | 100 |
| Nestable | `BMatch` | 33,002 | 200 |
| Nestable | `BPattern` | 9,492 | 1 |
| Nestable | `BStructural` | 13,000 | 60 |
| Nestable | `BMatchNext` | 1,771 | 100 |

The nestable prices and all dynamic counts are unchanged. The original shallow budget rows used
27,493/19,134 CPU. They are repriced exactly, without reevaluation, as:

```text
revised shallow CPU
  = recorded shallow CPU
  - 303  * recorded BMatch count
  - 1,824 * recorded BMatchWork count
```

The source rows are [comparison-budget.csv](results/comparison-budget.csv) and the joined case data
are [comparison-cases.csv](results/comparison-cases.csv). Those files remain immutable records of
the original run; all revised figures in this document are deterministic arithmetic over their
stored counts.

## Equivalent deconstruction, different lowering

The 27 cases are the product of three families, depths 1/4/16, and widths 1/4/16. For each case,
both implementations deconstruct the same `Data` value to terminal integer 42.

- Nestable matching encodes the recursive deconstruction in one recursive pattern under one UPLC
  `Match`.
- Shallow matching emits one structural `Match` at each data level and one terminal `data-i`
  `Match`.
- A shallow map level emits one additional Pair `Match`, because `data-map ... (bind)` captures an
  entry pair and a later Match extracts its value.

The CEK categories are consequently not interchangeable. Nestable `BPattern` includes recursive
pattern actions; shallow `BMatchWork` is a deliberately coarse immediate-field/alternative/capture
quantum. Comparing the individual prices as if they represented the same operation would be
misleading. Total budget is the valid comparison.

## Exact dynamic-count model

Let `d` be depth, `w` be immediate width, and `q` be the number of map levels. For pure Constr and
List families, `q = 0`; for the alternating Constr/List/Map family, `q = floor(d / 3)`.

| Counter | Shallow | Nestable |
|---|---:|---:|
| `BMatch` | `d + 1 + q` | `2` |
| `BMatchWork` | `d(w + 1) + 3q + 2` | — |
| `BPattern` | — | `13d + 3 + 6q` |
| `BStructural` | — | `dw + 1 + 2q` |
| `BMatchNext` | — | `0` |

The nestable count of two `BMatch` charges is one Match-entry charge plus one successful-capture
charge, not two AST `Match` nodes. `BMatchNext` is zero because these are successful,
single-alternative deconstructions; alternative-heavy failure dispatch is outside this comparison.

## Closed-form production budgets

The stored rows reduce to the following exact equations. They include ordinary CEK work as well as
matcher-specific work.

```text
revised shallow CPU =
  109910 + 76500d + 17310dw + 111120q

nestable CPU =
  155580 + 123396d + 13000dw + 82952q

shallow memory =
  800 + 500d + 100dw + 700q

nestable memory =
  863 + 13d + 60dw + 126q
```

The CPU difference is:

```text
shallow - nestable =
  4310dw - 46896d + 28168q - 45670
```

This exposes the tradeoff directly: shallow lowering has a substantially cheaper depth term, but
its coarse work quantum grows 4,310 CPU faster per immediate field. Each map level also adds a
28,168-CPU disadvantage from Pair extraction.

The CPU crossover widths under the revised prices are:

| Depth | Pure Constr/List | Alternating |
|---:|---:|---:|
| 1 | `w < 21.477` | `w < 21.477` |
| 4 | `w < 13.530` | `w < 11.896` |
| 16 | `w < 11.543` | `w < 9.501` |

Thus every sampled width-1 and width-4 case favors shallow CPU. At width 16, the depth-1 cases
still favor shallow, while all six depth-4/depth-16 cases favor nestable.

The memory difference is unchanged:

```text
shallow - nestable =
  -63 + 487d + 40dw + 574q
```

It is positive for every valid shape in this matrix. These are logical `ExMemory` policy units,
not host bytes, allocation, or maximum residency.

## Aggregate results

All ratios are shallow divided by nestable; values below one favor shallow.

| Statistic | Original prices | Revised prices | Interpretation |
|---|---:|---:|---|
| Geometric mean of 27 total-CPU ratios | 0.887566 | 0.837073 | Typical equally weighted shape is 16.29% cheaper under revised shallow prices |
| Ratio of summed total CPU, one of every case | 0.981359 | 0.915886 | Expensive width-16 cases receive their absolute weight |
| Geometric mean of Match-only CPU ratios | 0.7169 | 0.664141 | Removes ordinary CEK lowering overhead |
| Ratio of summed Match-only CPU | 0.833344 | 0.765979 | Shallow Match categories save 10,511,280 units over the full matrix |
| Geometric mean of total-memory ratios | 2.286848 | 2.286848 | Memory policy is unchanged |
| Ratio of summed total memory | 2.430032 | 2.430032 | 261,000 shallow versus 107,406 nestable |

Shallow uses less total CPU in 21/27 cases and less Match-only CPU in 27/27 cases. It uses more
logical memory in all 27 cases.

The difference between geometric and summed ratios matters. A geometric mean describes a typical
shape when each shape has equal weight. The summed ratio gives large absolute-budget cases more
weight. Neither estimates a production workload distribution.

### Grouped total-CPU ratios

| Group | Original S/N | Revised S/N | Revised shallow wins |
|---|---:|---:|---:|
| All cases | 0.887566 | 0.837073 | 21/27 |
| Alternating | 0.913511 | 0.861763 | 7/9 |
| Constr | 0.874872 | 0.824995 | 7/9 |
| List | 0.874872 | 0.824995 | 7/9 |
| Depth 1 | 0.844942 | 0.800421 | 9/9 |
| Depth 4 | 0.899464 | 0.847283 | 6/9 |
| Depth 16 | 0.920009 | 0.864856 | 6/9 |
| Width 1 | 0.739695 | 0.710613 | 9/9 |
| Width 4 | 0.860443 | 0.813100 | 9/9 |
| Width 16 | 1.098571 | 1.015111 | 3/9 |

## Matcher cost versus lowering overhead

The exact decomposition is:

```text
shallow Match CPU =
  61810 + 44500d + 17310dw + 79120q

shallow ordinary CEK CPU =
  48100 + 32000(d + q)

nestable Match CPU =
  107480 + 123396d + 13000dw + 82952q

nestable ordinary CEK CPU =
  48100
```

Across one copy of all 27 cases:

| Component | Shallow | Nestable | Shallow/Nestable |
|---|---:|---:|---:|
| Match CPU | 34,404,660 | 44,915,940 | 0.765979 |
| Ordinary CEK CPU | 7,922,700 | 1,298,700 | 6.100485 |
| Total CPU | 42,327,360 | 46,214,640 | 0.915886 |
| Total memory | 261,000 | 107,406 | 2.430032 |

The shallow matcher categories save 10,511,280 CPU, but sequential lowering spends 6,624,000 more
ordinary CEK CPU. The net saving is therefore 3,887,280 CPU. This is the central budget tradeoff:
the shallow matcher is cheaper, while representing recursion as later Match nodes adds ordinary CEK
overhead.

## Every case

`M/W` means shallow `BMatch/BMatchWork`; `M/P/S/N` means nestable
`BMatch/BPattern/BStructural/BMatchNext`.

| Case | Shallow M/W | Nestable M/P/S/N | Revised shallow CPU | Nestable CPU | CPU S/N | CPU delta | Shallow memory | Nestable memory | Mem S/N |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `alternating-d1-w1` | 2/4 | 2/16/2/0 | 203,720 | 291,976 | 0.698 | -88,256 | 1,400 | 936 | 1.496 |
| `alternating-d1-w4` | 2/7 | 2/16/5/0 | 255,650 | 330,976 | 0.772 | -75,326 | 1,700 | 1,116 | 1.523 |
| `alternating-d1-w16` | 2/19 | 2/16/17/0 | 463,370 | 486,976 | 0.952 | -23,606 | 2,900 | 1,836 | 1.580 |
| `alternating-d4-w1` | 6/13 | 2/61/7/0 | 596,270 | 784,116 | 0.760 | -187,846 | 3,900 | 1,281 | 3.044 |
| `alternating-d4-w4` | 6/25 | 2/61/19/0 | 803,990 | 940,116 | 0.855 | -136,126 | 5,100 | 2,001 | 2.549 |
| `alternating-d4-w16` | 6/73 | 2/61/67/0 | 1,634,870 | 1,564,116 | 1.045 | 70,754 | 9,900 | 4,881 | 2.028 |
| `alternating-d16-w1` | 22/49 | 2/241/27/0 | 2,166,470 | 2,752,676 | 0.787 | -586,206 | 13,900 | 2,661 | 5.224 |
| `alternating-d16-w4` | 22/97 | 2/241/75/0 | 2,997,350 | 3,376,676 | 0.888 | -379,326 | 18,700 | 5,541 | 3.375 |
| `alternating-d16-w16` | 22/289 | 2/241/267/0 | 6,320,870 | 5,872,676 | 1.076 | 448,194 | 37,900 | 17,061 | 2.221 |
| `constr-d1-w1` | 2/4 | 2/16/2/0 | 203,720 | 291,976 | 0.698 | -88,256 | 1,400 | 936 | 1.496 |
| `constr-d1-w4` | 2/7 | 2/16/5/0 | 255,650 | 330,976 | 0.772 | -75,326 | 1,700 | 1,116 | 1.523 |
| `constr-d1-w16` | 2/19 | 2/16/17/0 | 463,370 | 486,976 | 0.952 | -23,606 | 2,900 | 1,836 | 1.580 |
| `constr-d4-w1` | 5/10 | 2/55/5/0 | 485,150 | 701,164 | 0.692 | -216,014 | 3,200 | 1,155 | 2.771 |
| `constr-d4-w4` | 5/22 | 2/55/17/0 | 692,870 | 857,164 | 0.808 | -164,294 | 4,400 | 1,875 | 2.347 |
| `constr-d4-w16` | 5/70 | 2/55/65/0 | 1,523,750 | 1,481,164 | 1.029 | 42,586 | 9,200 | 4,755 | 1.935 |
| `constr-d16-w1` | 17/34 | 2/211/17/0 | 1,610,870 | 2,337,916 | 0.689 | -727,046 | 10,400 | 2,031 | 5.121 |
| `constr-d16-w4` | 17/82 | 2/211/65/0 | 2,441,750 | 2,961,916 | 0.824 | -520,166 | 15,200 | 4,911 | 3.095 |
| `constr-d16-w16` | 17/274 | 2/211/257/0 | 5,765,270 | 5,457,916 | 1.056 | 307,354 | 34,400 | 16,431 | 2.094 |
| `list-d1-w1` | 2/4 | 2/16/2/0 | 203,720 | 291,976 | 0.698 | -88,256 | 1,400 | 936 | 1.496 |
| `list-d1-w4` | 2/7 | 2/16/5/0 | 255,650 | 330,976 | 0.772 | -75,326 | 1,700 | 1,116 | 1.523 |
| `list-d1-w16` | 2/19 | 2/16/17/0 | 463,370 | 486,976 | 0.952 | -23,606 | 2,900 | 1,836 | 1.580 |
| `list-d4-w1` | 5/10 | 2/55/5/0 | 485,150 | 701,164 | 0.692 | -216,014 | 3,200 | 1,155 | 2.771 |
| `list-d4-w4` | 5/22 | 2/55/17/0 | 692,870 | 857,164 | 0.808 | -164,294 | 4,400 | 1,875 | 2.347 |
| `list-d4-w16` | 5/70 | 2/55/65/0 | 1,523,750 | 1,481,164 | 1.029 | 42,586 | 9,200 | 4,755 | 1.935 |
| `list-d16-w1` | 17/34 | 2/211/17/0 | 1,610,870 | 2,337,916 | 0.689 | -727,046 | 10,400 | 2,031 | 5.121 |
| `list-d16-w4` | 17/82 | 2/211/65/0 | 2,441,750 | 2,961,916 | 0.824 | -520,166 | 15,200 | 4,911 | 3.095 |
| `list-d16-w16` | 17/274 | 2/211/257/0 | 5,765,270 | 5,457,916 | 1.056 | 307,354 | 34,400 | 16,431 | 2.094 |

The lowest revised CPU ratio is 0.689 (`constr-d16-w1` and `list-d16-w1`). The highest is 1.076
(`alternating-d16-w16`).

## Current Cardano transaction limits

The active mainnet `maxTxExecutionUnits` snapshot used for this analysis is:

```text
CPU / steps: 10,000,000,000
Memory:      16,500,000
```

The values were [queried from the active mainnet epoch 647 parameters](https://api.koios.rest/api/v1/epoch_params?_epoch_no=647&select=epoch_no,max_tx_size,max_tx_ex_mem,max_tx_ex_steps,max_block_ex_mem,max_block_ex_steps)
and match the
[enacted parameter update](https://app.cgov.io/governance/c21b00f90f18fce4003edf42b0b0d455126e01c946e80cc5341a9f9750caf795%3A0).
They are governance-controlled; a future audit must query the active protocol parameters again.

The largest revised shallow comparison case (`alternating-d16-w16`) consumes 0.0632% of the
transaction CPU limit and 0.230% of the memory limit. These 27 cases isolate deconstruction; they
are not transaction-limit saturation tests.

For Match-heavy adversaries, the unchanged memory prices are the binding category before CPU:

| Pure category | CPU-only ceiling | Memory-only ceiling |
|---|---:|---:|
| `BMatch` at 27,190 CPU / 200 memory | 367,782 | 82,500 |
| `BMatchWork` at 17,310 CPU / 100 memory | 577,700 | 165,000 |

These are accounting ceilings for idealized category-only streams starting with a full transaction
budget. Bounded CEK cost slippage can execute up to 199 additional accumulated machine steps before
the next spend. Using the largest stored one-sided upper slopes, the accounting ceilings correspond
to about 2.27 ms of fixed Match time or 3.16 ms of MatchWork time on the calibration host. Lowering
the CPU prices does not change those particular ceilings because the memory prices remain 200/100.
Actual programs execute other CEK categories, and a mixed program with spare memory but little CPU
can admit more Match work under the lower CPU prices; the category-only argument does not cover it.

This is not a hardware-independent wall-time proof. One CPU unit is calibrated as a picosecond on
the calibration reference machine, and wall time can include scheduler interruption. The active
transaction budget, not serialized size or an external timeout, is the termination mechanism for
adversarial evaluation.

## Limitations

- This is a successful single-alternative deconstruction matrix. It does not compare
  alternative-heavy failure dispatch, where shallow's coarse work quantum was calibrated.
- Constr and List have identical budget topology here; their host timings differ slightly, but their
  execution-budget rows do not.
- Each implementation uses its own experimental production cost model. Budget ratios are therefore
  partly policy comparisons, not direct timing ratios.
- `ExMemory` is a logical execution-budget quantity and must not be interpreted as RSS.
- The CPU timing matrix remains the original 270-process run. Revised budget arithmetic does not
  revise or predict those host timings.
- The current protocol limits are time-varying governance parameters and must be refreshed for any
  later safety review.
