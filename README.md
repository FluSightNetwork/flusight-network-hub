# FluSight Network Hub (archive)

A [hubverse](https://hubverse.io)-format archive of the influenza forecasts collected by the
[FluSight Network](https://github.com/FluSightNetwork/cdc-flusight-ensemble) (FSN) for the
2010/11–2019/20 US influenza seasons: 30+ component models and the FSN collaborative ensembles,
both as **real-time** submissions (2017/18–2019/20) and as the **training** (out-of-sample backcast)
series used to fit ensemble weights.

> **Status:** under construction. This repository is being filled in a sequence of pull requests:
> (1) hub setup, pipeline and validation; (2) target data and auxiliary data; (3) model output, in
> batches (real-time, training, cross-validated ensembles). See [`PLAN.md`](PLAN.md) for the full
> design and decision log.

## What is forecast

Weighted influenza-like illness (wILI) from CDC's ILINet, for the US and the 10 HHS regions
(`location`: `US National`, `HHS Region 1` … `HHS Region 10`). Forecasts are made each week
(`origin_date` = the Saturday ending the most recent week of data, MMWR week *EWxx* in the source
file names).

| `target` | Meaning | `horizon` / `target_end_date` | Output types |
|---|---|---|---|
| `ili perc` | wILI % for the week ending `target_end_date` | 1–4 weeks ahead | `pmf`, `median` |
| `season peak perc` | highest weekly wILI % of the season | empty | `pmf` |
| `season onset wk` | first week of 3 consecutive weeks at/above the regional baseline | empty | `pmf` |
| `season peak wk` | week of the season's highest wILI | empty | `pmf` |

- **pmf bins.** wILI was scored on a one-decimal scale, so `ili perc` / `season peak perc` bins are
  labelled by their left edge `"0.0"` … `"13.0"`; `"13.0"` is the open bin [13, 100]. Week targets
  are labelled by the Saturday ending each MMWR week (`YYYY-MM-DD`), plus `"none"` (no onset) for
  `season onset wk`. Each season is its own round in `hub-config/tasks.json`.
- **Medians are computed, not submitted.** FluSight "point" forecasts were inconsistently defined
  (median bin, mean, or other; several models' points contradict their own pmf). The `median` here is
  the left edge of the first bin whose cumulative probability reaches 0.5 — exact on the one-decimal
  scale; 13.0 where it falls in the open bin. Only for weekly `ili perc`, as in the current CDC
  FluSight hub. The original points are kept unchanged in `auxiliary-data/`.

## Two records: real-time and training — do not mix them

| Model ID | Record | Contents |
|---|---|---|
| `<team>-<model>` | real-time | forecasts as submitted in real time (2017/18–2019/20) |
| `<team>-<model>_train` | training | the model's 2010/11–2018/19 series as FSN held it in `component-models/` (backcasts plus copies of real-time files) |
| `FSNetwork-<ABBR>` | real-time | FSN ensembles; for the ensemble sent to CDC, the file actually submitted |
| `FSNetwork-<ABBR>_cv` | cross-validated | leave-one-season-out ensembles, exactly as FSN built them |
| `FSNetwork-<ABBR>_cv_repaired` | cross-validated | the same, with FSN's week-52 stacking bug repaired (see below) |

**Never combine plain IDs with `_train` / `_cv` IDs in one analysis**: ~1,100 training files are
byte-identical copies of real-time files, so the same forecast would be counted twice. Use plain IDs
for real-time evaluation and `_train` + `_cv` for training / cross-validation work. Each model's
metadata (`model-metadata/`) gives its `forecast_mode` and paired ID.

- **Real-time** means first committed to the FSN repository no more than 3 days after the FluSight
  due date (the Monday 9 days after `origin_date`); the last version committed by then is used.
  Forecasts committed later are not in the real-time record.
- **Training** is pinned to the 2019-10-25 commit from which FSN built its cross-validated ensembles
  and 2019/20 weights (exception: the ReichLab `kcde_backfill` models use their 2019-10-26 re-run).
  Models FSN later removed (e.g. Delphi `…_PD`, LANL-DBM, UTAustin-edm, ReichLab-KCDE) are included
  at their last state; they are the components of the 2017/18 real-time ensemble.

## Changes made to the source data

Every change is logged; everything else is bit-identical to the source (verified for all 128M
source bin values, `validation/roundtrip.csv`).

- **Bin labels** standardised (`1` vs `1.0`, week numbers → dates; CU's week numbers past 52 rolled over).
- **Renormalisation**: pmfs whose probabilities summed to within 0.1 of 1 were divided by their sum
  (CDC's 2015/16 rule); larger deviations were excluded (`excluded_output/`). Log: `validation/changes.parquet`.
- **Repaired cv ensembles** (`…_cv_repaired`): FSN's stacking code joined bins on start *and* end; CU-BMA
  writes the week-52 bin as [52, 1) while most models write [52, 53), so other models' week-52
  probability (week 53 in 2014/15) was dropped from every cv ensemble's onset/peak-week forecasts.
  The repair recomputes only that bin from FSN's own components and weights; all other values are
  identical to FSN's (`validation/cv-repair.csv`). The originals are kept as `…_cv`.

## Target data

`target-data/time-series.csv` (weekly wILI) and `target-data/oracle-output.parquet` (hubverse oracle
output: 1 for the observed bin, 0 otherwise; observed value for medians), keyed like the model output.

- 2010/11–2018/19: FSN's own truths (`scores/target-multivals.csv`). Where FSN listed several tied peak
  weeks (14 location-seasons), the week with the highest **unrounded** ILINet wILI is used
  (`src/peak_week_ties.csv`).
- 2019/20 (and 11 late-2018/19 weeks): FSN computed no truths; they are **derived** with FSN's
  definitions from ILINet as of issue 202028 (FSN's week-28 convention) and CDC's 2019/20 baselines.
  The method reproduces all FSN truths for 2010/11–2018/19 exactly. `truth_source` marks each row.
- **2019/20 onset and peak use a season ending EW09-2020** (week ending 2020-02-29) so that
  COVID-19-affected spring weeks are not scored as the peak. Weekly `ili perc` truths are not cut.

## Using the data with hubverse tools

```r
library(hubData)
hub <- connect_hub("path/to/flusight-network-hub", file_format = "parquet")
hub |> dplyr::filter(target == "ili perc", output_type == "pmf",
                     !grepl("_(train|cv|cv_repaired)$", model_id)) |>   # real-time record only
  hubData::collect_hub()
```

Known tool limitations (see `src/11_smoke_modelimportance.R`):

- Seasonal targets have empty `horizon` / `target_end_date`; hubEvals/scoringutils drop rows with
  missing task IDs, so remove those all-empty columns before scoring seasonal targets.
- `modelimportance::model_importance()` renames `origin_date` to `reference_date` in the forecasts but
  not in the oracle data; rename the oracle column too.
- Scores use the standard (single-bin) log score, not FluSight's multi-bin score.

## Repository layout

| Path | Contents |
|---|---|
| `hub-config/` | `tasks.json`, `admin.json`, `model-metadata-schema.json` (hubverse schema v6.0.0) |
| `model-output/` | one parquet file per model and round *(added in later PRs)* |
| `model-metadata/` | one YAML file per model ID |
| `target-data/` | time series and oracle output *(PR 2)* |
| `auxiliary-data/` | original point forecasts, file provenance, ILINet snapshots *(PR 2)* |
| `excluded_output/` | forecasts excluded by the quality rules *(with model output)* |
| `src/` | the conversion pipeline (see `src/README.md`) |
| `validation/` | manifests, file map, change logs and check results |
| `.github/workflows/` | CI: hub config validation, model-output/metadata validation on PRs (submission-window check skipped), round-aware target-data validation |

## Source and licence

Source: [FluSightNetwork/cdc-flusight-ensemble](https://github.com/FluSightNetwork/cdc-flusight-ensemble)
(master `8c3100af`, 2020-05-04, plus earlier versions from its full git history). This repository is
licensed [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/), as is the source (see [`LICENSE`](LICENSE)).
Related archive: [hubverse-org/flusight_hub_archive](https://github.com/hubverse-org/flusight_hub_archive)
(CDC FluSight submissions, 2015/16–2019/20).
