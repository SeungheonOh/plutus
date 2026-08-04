# Shallow `Match` calibration

This benchmark calibrates exactly two CEK costs: fixed `BMatch` entry and one conservative
`BMatchWork` quantum. Its cases are paired controls/workloads at four sizes. Before Criterion sees
a benchmark, the runner executes its recipe with unit machine costs and checks exact dynamic
`BMatch`, `BMatchWork`, `BCase`, and `BLamAbs` counts.

The charged work-unit contract is:

- one for each alternative after the first;
- one for each requested immediate field;
- one additional unit for every root or field capture;
- one for every started eight-byte chunk of a ByteString literal.

The `rest-suffix` family is an audit: changing the ignored suffix length must not change its
`BMatchWork` count, and the analysis never uses that family to select a cost.

From the repository root, build once and locate the executable:

```console
cabal build plutus-benchmark:bench:matching-costing
bench=$(cabal list-bin plutus-benchmark:bench:matching-costing)
```

Generate metadata without constructing any terms, then collect Criterion CSV on an otherwise idle
machine. Criterion options can shorten exploratory runs; final calibration should use a suitable
time limit and identical machine settings throughout.

```console
MATCHING_COSTING_MODE=metadata "$bench" > matching-metadata.csv
"$bench" --csv matching-timings.csv
python3 plutus-benchmark/matching/costing/analyse.py \
  matching-metadata.csv matching-timings.csv \
  --machine-costs plutus-core/cost-model/data/cekMachineCostsE.json \
  > matching-fit.json
```

The analysis uses ordinary least squares over paired time differences. It subtracts the known
`Case` and `LamAbs` CPU charges recorded in the metadata, reports slope/intercept/R² and a
one-sided 95% upper slope for every family, rejects negative or low-R² fits, and proposes
`ceil(max accepted upper slope)` independently for `BMatch` and `BMatchWork`. No production cost
constant is changed by the benchmark or script.

Set `MATCHING_COSTING_CASE` to a metadata `name` to run and validate only one case while diagnosing
a noisy family.
