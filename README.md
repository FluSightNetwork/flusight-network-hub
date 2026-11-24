# FluSight Network Hub (archive)

A [hubverse](https://hubverse.io)-format archive of the influenza forecasts collected by the
[FluSight Network](https://github.com/FluSightNetwork/cdc-flusight-ensemble) (FSN) for the
2010/11–2019/20 US influenza seasons: 30+ component models, each with its **real-time** submissions
(2017/18–2019/20) and the **training** (out-of-sample backcast) series used to fit ensemble weights,
the FSN collaborative ensembles, and CDC's unweighted average of FluSight submissions.

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

## Model IDs and real-time forecasts

| Model ID | Contents |
|---|---|
| `<team>-<model>` | every round of a component model: real-time forecasts where they exist, FSN's training backcasts otherwise |
| `<team>-<model>1`, `…2` | one ID per version, for models retrained between seasons (`CU-BMA`, `Protea-Cheetah/Kudu/Springbok`) |
| `FluSight-unweighted_avg` | CDC's unweighted average of FluSight submissions, 2015/16–2019/20 (real-time) |
| `FSNetwork-<ABBR>_<YYYY_YY>` | one FSN ensemble build: the leave-one-season-out forecasts FSN made before season YYYY/YY to choose its ensemble, plus that season's real-time forecasts (for the ensemble sent to CDC, the file actually submitted) |
| `FSNetwork-<ABBR>_<YYYY_YY>_repaired` | the same build with FSN's last-week stacking bug repaired (see below) |

FSN rebuilt its ensembles before each season it ran in real time (`src/ensemble_builds.csv`):

| Build | Methods (`ABBR`) | Leave-one-season-out seasons | Real-time season | Sent to CDC |
|---|---|---|---|---|
| `_2017_18` (2017-11-04) | CW, EW, TRW, TTW, TW | 2010/11–2016/17 | 2017/18 | TTW |
| `_2018_19` (2018-10-23) | CW, EW, TRW, TTW, TW | 2010/11–2017/18 | 2018/19 | TW |
| `_2019_20` (2019-10-25) | CW, EW, SRTRW, TTW, TW | 2010/11–2018/19 | 2019/20 | TTW |

CW constant weights, EW equal weights, TW target-based, TTW target-type-based, TRW target-and-region-based,
SRTRW static regularized target-region weights. Each build covers weeks EW43–EW18 of the earlier seasons.

**Which forecasts were made in real time?** Each model's metadata lists its `real_time_seasons`, and
`auxiliary-data/file-provenance.csv` has an exact `is_real_time` flag for every file. For real-time
evaluation, filter on `is_real_time`; for ensemble training, use all rounds.

- **Real-time** means first committed to the FSN repository (or CDC's, for the unweighted average) no
  more than 3 days after the FluSight due date (the Monday 9 days after `origin_date`); the last version
  committed by then is used.
- **Training backcasts** are FSN's `component-models/` series as of the 2019-10-25 commit from which FSN
  built its cross-validated ensembles and 2019/20 weights (exception: the ReichLab `kcde_backfill` models
  use their 2019-10-26 re-run). Models FSN later removed (e.g. Delphi `…_PD`, LANL-DBM, UTAustin-edm,
  ReichLab-KCDE) are included at their last state.
- **One version of each forecast.** Where FSN's training copy of a round is identical to the real-time
  file, it is not repeated. Where it differs (2 files), the real-time file is used and the training
  version is kept unchanged in `auxiliary-data/superseded-forecasts.parquet`. A few rounds exist only as
  real-time-folder files committed after the cutoff; they are included with `is_real_time = FALSE`.
- **Versions.** CU-BMA and the three Protea models were retrained before the 2019/20 season. Version 1
  holds the original backcasts plus the 2017/18–2018/19 (CU) or 2018/19 (Protea) real-time forecasts;
  version 2 holds the retrained backcasts plus 2019/20. Metadata `fsn_ensemble_component_seasons`
  records which seasons' FSN ensembles each model (version) was a component of.
- **Ensemble builds overlap.** The same season appears in several builds (e.g. 2015/16 is a
  leave-one-season-out season in all three; 2017/18 is real-time in `_2017_18` and leave-one-season-out
  in `_2018_19` and `_2019_20`). Pick one build per analysis; the builds differ in components and weights.

## Changes made to the source data

Every change is logged; everything else is bit-identical to the source (verified for all 128M
source bin values, `validation/roundtrip.csv`).

- **Bin labels** standardised (`1` vs `1.0`, week numbers → dates; CU's week numbers past 52 rolled over).
- **Renormalisation**: pmfs whose probabilities summed to within 0.1 of 1 were divided by their sum
  (CDC's 2015/16 rule); larger deviations were excluded (`excluded_output/`). Log: `validation/changes.parquet`.
- **Repaired ensemble builds** (`…_repaired`): FSN's stacking code joined bins on start *and* end.
  Components label the last week of the year differently ([52, 1) vs [52, 53); week 53 in 2014/15), so
  some components' probability for that bin was dropped from leave-one-season-out onset/peak-week
  forecasts. The repair recomputes only that bin from FSN's own components and weights; all other values,
  and all real-time files, are identical to FSN's (`validation/cv-repair.csv`). The originals are kept
  under the unrepaired IDs.
- **Stale files not converted.** The 2017/18 and 2018/19 build trees still held EW19/EW20
  leave-one-season-out files from an interim build of 2017-10-24 that FSN never rebuilt; they are listed
  in `validation/file-map-excluded.csv`.

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
                     !startsWith(model_id, "FSNetwork-")) |>
  hubData::collect_hub()
prov <- read.csv("path/to/flusight-network-hub/auxiliary-data/file-provenance.csv")
# keep real-time forecasts only: semi-join on model_id + origin_date where prov$is_real_time
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
| `auxiliary-data/` | original point forecasts, file provenance (`is_real_time`), superseded forecasts, ILINet snapshots *(PR 2)* |
| `excluded_output/` | forecasts excluded by the quality rules *(with model output)* |
| `src/` | the conversion pipeline (see `src/README.md`) |
| `validation/` | manifests, file map, change logs and check results |
| `.github/workflows/` | CI: hub config validation, model-output/metadata validation on PRs (submission-window check skipped), round-aware target-data validation |

## Source and licence

Source: [FluSightNetwork/cdc-flusight-ensemble](https://github.com/FluSightNetwork/cdc-flusight-ensemble)
(master `8c3100af`, 2020-05-04, plus earlier versions from its full git history), and, for
FluSight-unweighted_avg 2018/19–2019/20, [cdcepi/FluSight-forecasts](https://github.com/cdcepi/FluSight-forecasts)
(master `b1ac3830`, CC BY 4.0). This repository is
licensed [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/), as is the source (see [`LICENSE`](LICENSE)).
Related archive: [hubverse-org/flusight_hub_archive](https://github.com/hubverse-org/flusight_hub_archive)
(CDC FluSight submissions, 2015/16–2019/20).
