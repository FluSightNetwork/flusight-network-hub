# Plan: FluSight Network forecasts → hubverse archive hub

Status: draft, 2026-11-22. Nothing built yet.

## Goal

Convert every forecast in [FluSightNetwork/cdc-flusight-ensemble](https://github.com/FluSightNetwork/cdc-flusight-ensemble) (2010/11–2019/20) into a hubverse-format archive hub that:

1. passes `hubAdmin` config validation and `hubValidations` on every model-output file;
2. can be traced row by row to the source. Every change (bin labels rewritten, probabilities renormalised, rows excluded, medians computed) is logged, and everything else is shown bit-identical;
3. works directly with [modelimportance](https://github.com/mkim425/modelimportance) (pmf → log score, median → absolute error). [alloscore2](https://github.com/reichlab/alloscore2) is quantile-only today; see "Downstream" below.

Design reference: [hubverse-org/flusight_hub_archive](https://github.com/hubverse-org/flusight_hub_archive). We follow its layout and naming, but differ where it changed data (CDF conversion, `Point → mean`).

## Source inventory (pinned to commit `8c3100af`, 2020-05-04)

| Source dir | Contents | Seasons | Files |
|---|---|---|---|
| `component-models/` | 27 component models, retrospective before each model's `real_time_start_season`, real-time after | 2010/11–2018/19 | 7,943 |
| `real-time-component-models/` | same 27 models, real-time | 2019/20 | 632 |
| `cv-ensemble-models/` | 5 FSNetwork ensembles, leave-one-season-out CV | 2010/11–2018/19 | 1,265 |
| `real-time-ensemble-models/` (+ `archive-2017-2018/`, `archive-2018-2019/`) | 5–6 FSNetwork ensembles, real-time | 2017/18–2019/20 | 385 |
| `submissions/`, `submissions-archive/` | ensemble files sent to CDC | 2017/18–2019/20 | 80 |

> **Scope note:** the profile and every count in this section (and the 13+ median counts, NA counts, sum deviations and point-vs-median tables elsewhere) were computed on **master only**. Before the two-record design, the conversion set was estimated at about **13,400 files (~107M rows)**. The two-record design adds about 1,160 duplicate real-time files (~9M rows), for a new estimate of **~14,500 files and ~116M rows**:
> - 10,305 master files,
> - minus about 80 submission duplicates and the EW63 file,
> - plus about 3,150 model × round files recovered from history: Delphi `PackageDefaults` ×5 (246 each), Delphi EmpiricalBayes ×2 and Stat (260 each), LANL_DBM 260, UTAustin_edm 270, ReichLab_kcde 289, FluSight_unweighted_avg 85, cv TRW 239.
>
> All profile statistics are **recomputed on the actual conversion set in Phase 1** (step 02/03) and replace the numbers here.

Profile of all 10,305 forecast CSVs on master (82.7M rows):
- One schema throughout. Only the header capitalisation differs.
- No duplicate rows, no non-numeric bin values, all 11 locations in every file.
- Bins: 131 per ILI target. Onset and peak week have 33–35 bins (2014/15 had an MMWR week 53).

Issues found:
- **Bin labels written two ways** (`1` vs `1.0`, `0` vs `0.0`). These must be canonicalised.
- **5,336 missing Point values** (`NA`/`NaN`/empty), all in Point rows, mostly onset and peak week. Missing points mean the median fell in the onset `"none"` bin.
- **Probability sums.** Components and real-time ensembles are within 0.0143 of 1. Many are about 1e-5 off, which still fails `hubValidations`' roughly 1.5e-8 tolerance.
  - **cv-ensemble onset and peak-week pmfs miss 1 by up to 0.97** (1,131 files have a gap above 0.1). Working hypothesis, not yet confirmed: the ensembles were built wrongly when components labelled bins `1` vs `1.0`, so some components' probabilities never got added in.
- **Submissions duplicate real-time ensembles.** The 8 weeks checked are byte-identical to `real-time-ensemble-models/`. A few weeks have two submission files (e.g. EW01-2020 on 01-13 and 01-16).
- **Tied peak weeks:** 14 season × location cases (464 truth rows) where several weeks count as the peak.

## Decisions

### Confirmed with the user
| Topic | Decision |
|---|---|
| ILI targets (1–4 wk ahead, season peak %) | `pmf`, exact values, labelled by the bin's left edge (`"0.0"` … `"13.0"`). No CDF conversion. |
| Onset and peak week labels | Saturday ending the MMWR week (`YYYY-MM-DD`), matching the current CDC FluSight hub; plus `"none"` for onset. |
| Point forecasts | Replaced by **medians computed from each pmf** (rule below), **for the weekly `ili perc` targets (1–4 wk ahead) only**. Seasonal targets (onset, peak week, peak %) get no median, as in the current CDC FluSight hub. All original points are kept untouched in `auxiliary-data/`. |
| Renormalisation | Renormalise pmfs that miss 1 by 0.1 or less (the CDC 2015/16 rule used by the reference archive). Bigger problems go to a review queue and are decided as they come up. |
| Real-time vs training | **Revised 2026-11-23:** one model ID per component model holding every round, real-time version preferred; `real_time_seasons` in metadata and a per-round `is_real_time` flag (see "Model structure"). Replaces the earlier plain/`_train` suffix design. |
| Ensemble model IDs | One per method per FSN pre-season build: `FSNetwork-<ABBR>_<YYYY_YY>` = that build's leave-one-season-out files + its season's real-time files; `…_repaired` copies (user decision 2026-11-23; replaced `FSNetwork-<ABBR>` / `_cv`). |
| Models removed from master | Included, using each file's last version from git history: Delphi `*_PackageDefaults`, `Delphi_EmpiricalBayes_*`, `Delphi_Stat_*`, `LANL_DBM`, `UTAustin_edm`, `ReichLab_kcde`, `FluSight_unweighted_avg`, and the old `cv-ensemble-models/target-and-region-based-weights` (→ `FSNetwork-TRW_cv`). |
| Real-time files edited after submission | Keep the version present at submission (the copy in `real-time-component-models/` during the season). Later edits are logged in the provenance table. |
| Scoring | No custom multi-bin log score (FluSight's version is improper). Archive data must work with the standard hubEvals log score. |
| Medians in the open 13–100 bin | Store 13.0. With medians limited to the weekly targets, that's **337 cases** (the other 1,878 were peak %). Reported points are not used. Flagged in `validation/median-13plus.csv`. |
| Badly named source files | If a file doesn't match a real round of the hub, it is not converted (logged in the file map as excluded). |
| Tied peak weeks | **Unrounded maximum** (user decision 2026-11-23): for each of FSN's 14 tied location-seasons, the observed peak week is the week with the highest unrounded wILI in ILINet (Delphi Epidata). Recorded in `src/peak_week_ties.csv` by `src/resolve_peak_week_ties.R`. |
| Target data coverage *(Phase 4)* | 2010/11–2018/19 from FSN's `scores/target-multivals.csv`. **2019/20 derived** (user decision 2026-11-23) by `src/compute_truths.R`: FSN's definitions applied to ILINet as of issue 202028 (FSN's eval-issue convention) with CDC 2019/20 baselines (FluSight R package `past_baselines`, saved as `src/baselines.csv`). The method reproduces all 297 seasonal and 3,575 weekly FSN truths for 2010/11–2018/19 exactly. ILINet snapshots are saved in `auxiliary-data/ilinet/`. **2019/20 season for onset/peak is cut at EW09-2020** (week ending 2020-02-29; user decision 2026-11-23) so COVID-19-affected spring weeks are not scored as onset/peak (HHS Region 2's peak moves from week 13 to week 6; HHS Region 3's from 12 to 6). Weekly `ili perc` truths are not cut. The 11 late-2018/19 target weeks FSN did not compute (week ending 2019-06-22) are derived the same way from issue 201928. Coverage: all 25,641 hub tasks have truth. Each row of `time-series.csv` records its `truth_source`. |
| hubEvals issue (missing task values drop rows) | File it **after** the hub is live, using this hub as the real example. |
| Real-time cutoff *(Phase 1)* | A file counts as real-time only if committed **no more than 3 days after the submission due date** (due = Monday, origin + 9 days; cutoff = origin + 12). The last version committed by the cutoff is used. Rounds with nothing by the cutoff are not real-time (45 rounds: UTAustin 18, ReichLab-KDE 7, CU 13, others 7). |
| Submitted ensembles *(Phase 1)* | For the ensemble sent to CDC (TTW 2017/18 and 2019/20, TW 2018/19), the real-time record uses the **file in `submissions/`**. FSN's regenerated ensemble file is logged, not converted (15 weeks differ). |
| Unmerged pull requests *(Phase 1)* | CU's EW14–16-2020 real-time files (21), found only in unmerged PRs, are **included and flagged** (`from_unmerged_pr`). |
| Delphi PackageDefaults *(Phase 1)* | **Separate IDs**: `Delphi-<model>_PD` (2017/18 version: backcasts + 2017/18 real-time). |
| kcde_backfill re-run *(Phase 1)* | `ReichLab-KCDE_NB` / `_PHB` backcasts use the **final (re-run) version** committed 2019-10-26, not the pinned one, even though FSN's scores, weights and cv ensembles were built from the pinned files. Logged as an exception to the pin. |
| Week numbers past 52 *(Phase 1)* | CU's `EW53-2017` … `EW65-2019` names roll over into the next year (EW53-2017 = EW01-2018). Every rolled-over file is identical to its correctly named copy where one exists. |
| Model structure *(revised 2026-11-23)* | One ID per component model; retrained models split into versions (`CU-BMA1/2`, `Protea-<model>1/2`); the 2 remaining one-file conflicts keep the real-time file, training version in `auxiliary-data/superseded-forecasts.parquet`; late real-time files fill rounds with no other version (`is_real_time = FALSE`). |
| FluSight-unweighted_avg 2018/19–2019/20 *(2026-11-23)* | Added from CDC's originals (`cdcepi/FluSight-forecasts`). |
| Hub identity *(Phase 1)* | Set 2026-11-23 in `admin.json`: "FluSight Network Forecast Archive", maintained by the Reich Lab, repository `FluSightNetwork/flusight-network-hub`. No S3/cloud. |
| cv-ensemble sums *(Phase 1)* | Diagnosed (`src/diag_cv_ensembles.R`): FSN's `stack_forecasts()` joined components on bin start **and** end; CU-BMA (first component) writes the week-52 bin as [52, 1) while most models write [52, 53), so other models' week-52 probability was dropped from every cv ensemble. Explains all 6,291 cv forecasts off by more than 0.1 (all week targets). **Repaired** (user decision 2026-11-23: keep original and repaired). Step 2 found the same bug in the 2017/18 and 2018/19 builds (week 53 of 2014/15, and smaller week-52 losses in every season); all 3,375 build files rebuild from FSN's components and weights to ≤ 9e-16 outside the repaired bin. |

### Proposed here (my calls; flag any you disagree with)
1. **Task ID columns** are `origin_date`, `location`, `target`, `horizon` and `target_end_date`. *(Confirmed by the user, 2026-11-22.)*
   - `target_end_date` is calculated from the others (`derived_task_ids`). It lets weekly truth data be keyed by week, as in the CDC hub.
   - `horizon` and `target_end_date` are empty for seasonal targets, the same pattern the CDC hub uses.
   - **No `season` or `origin_epiweek` columns.** Both are redundant with `origin_date`:
     - `season` would cost about 4 MB on disk but about 13 B/row (~1.5 GB) in memory when loaded.
     - Season can be computed from `origin_date` when needed, and seasonal truth rows simply carry `origin_date` (~700k rows, a few MB).
     - The link back to source `EWxx-YYYY` file names lives in `auxiliary-data/file-provenance.csv`.
     - Note: this differs from `flusight_hub_archive`, which has `origin_epiweek`.
2. **Round ID**: `origin_date` = the Saturday ending source EWxx (the same convention as the reference archive).
3. **Target names** match the reference archive so the two archives can be queried together: `ili perc`, `season peak perc`, `season onset wk`, `season peak wk`.
4. **`tasks.json` has one block per season** for onset and peak week, because each season has its own dates and the label list can't vary within a block. ILI targets can share one block.
5. **Submissions:** drop any file that is byte-identical (or value-identical) to the real-time ensemble file for the same week. Any that differ go to the review queue. Duplicate same-week submissions also go to review; the default is to keep the last one, as the reference archive did.
6. **No raw-data copy in this repo.** We cite the source commit plus a sha256 manifest of every source file. The source repo is public and archived on Zenodo. (The reference archive copied raw data into `original_raw_data/`; say if you want that instead.)
7. **Pipeline in R**, using the hubverse packages and data.table/arrow. Output as parquet.

## Rules

**Bin labels.** ILI labels are rewritten to one decimal place (`"0.0"`…`"13.0"`). Week labels become `MMWR(season-year, week) → Saturday date`, with weeks ≥ 40 in the first year of the season and weeks ≤ 20 in the second. `"none"` stays `"none"`.

**Renormalisation**, per forecast (model × origin × location × target):

| Sum of probabilities | Action |
|---|---|
| Within 1.5e-8 of 1 | Keep as is |
| Off by 0.1 or less | Divide by the sum; log the original sum |
| Off by more than 0.1, any negative value, or all missing | Move to `excluded_output/` and the review queue |

**Computed median (weekly `ili perc` targets only).** Observed wILI was rounded to one decimal place for scoring (`FluSight::create_truth()`), so each 0.1 bin holds exactly one possible observed value.
- The median is the left edge of the first bin (after renormalising) where the cumulative probability reaches 0.5. It is exact on the scale the outcome is measured on.
- If that bin is the open 13–100 bin, the median is stored as 13.0 and flagged.
- That happens in **337 cases** (60 / 42 / 77 / 158 for 1 / 2 / 3 / 4 wk ahead).
- The highest season peak observed in 2010/11–2018/19 was 12.7.
- Per-row detail is in `validation/median-13plus.csv`, which also still lists the 1,878 peak % cases for reference.

## Model structure (revised 2026-11-23)

*Replaces the earlier "two records" design (plain real-time IDs plus `_train` duplicates), which the user judged too heavy.*

**Component models: one model ID per model, holding every round.** For each round the hub file is, in order of preference:
1. **real-time**: the submitted file if one exists, else FSN's real-time file; the last version committed by the cutoff (due date + 3 days). `is_real_time = TRUE`.
2. **training**: FSN's `component-models/` series at the 2019-10-25 training pin (removed models at their last state; kcde_backfill re-run exception). Backcasts, plus copies of real-time files.
3. **late**: a real-time-folder file first committed after the cutoff, used only where no other version exists (19 rounds). `is_real_time = FALSE`.

- 1,169 training files are byte-identical copies of the chosen real-time file and are simply not repeated.
- **Superseded:** where a training file differs from the real-time file for the same round, the real-time file is used and the training version is kept unchanged in `auxiliary-data/superseded-forecasts.parquet` (2 files: CU-EAKFC_SIRS and ReichLab-KCDE, 2018/19).
- **Models retrained between seasons get one ID per version** (`src/model_versions.csv`; user decision 2026-11-23). Only CU-BMA and the three Protea models were retrained (every target changed, up to ~0.99 probability):
  | Version ID | Contents |
  |---|---|
  | `CU-BMA1` | backcasts as held before retraining (commit 33b2916^) + 2017/18 and 2018/19 real-time |
  | `CU-BMA2` | retrained backcasts 2010/11–2018/19 (training pin) + 2019/20 real-time |
  | `Protea-{Cheetah,Kudu,Springbok}1` | backcasts as held before retraining + 2018/19 real-time |
  | `Protea-{Cheetah,Kudu,Springbok}2` | retrained backcasts 2010/11–2018/19 + 2019/20 real-time |
  Each version is exactly the component used in the corresponding seasons' FSN ensembles. All of CU-BMA1's 2017/18 real-time files are byte-identical to the copies in its backcast tree. ReichLab SARIMA/KCDE changed only by a 2018-03-16 onset rounding-bug fix (onset target only), so they are not split; the fixed version is used.
- **Metadata:** `real_time_seasons` (every model), optional `fsn_ensemble_component_seasons` (from FSN's weights at each pre-season build: 21 / 21 / 27 components for 2017/18 / 2018/19 / 2019/20; `validation/ensemble-components.csv`), and `version_of` / `version_note` for split models.
- **Per-round flag:** `is_real_time` in `auxiliary-data/file-provenance.csv`. A few real-time seasons contain backcast-only edge rounds.

**FluSight-unweighted_avg:** FSN's copies for 2015/16–2017/18 (2016/17–2017/18 byte-identical to CDC's; FSN's 2015/16 copies use one-decimal bins, unlike CDC's 2015/16 originals), plus CDC's originals from `cdcepi/FluSight-forecasts` (`UnwghtAvg/`, CC BY 4.0) for 2018/19 (29 files) and 2019/20 (20 files, through EW09-2020), all committed by the real-time cutoff.

**Ensembles (step 2, done 2026-11-23):** one ID per method per pre-season build, `FSNetwork-<ABBR>_<YYYY_YY>` (user decision 2026-11-23), holding that build's leave-one-season-out forecasts plus its season's real-time forecasts, and a `_repaired` copy of each (30 IDs).
- Builds (`src/ensemble_builds.csv`): 2017-11-04 (`76d9a33`; CW, EW, TRW, TTW, TW), 2018-10-23 (`7b8ec6b`, weights `c1d1927`; same methods), 2019-10-25 (`58bd222`, weights `3b73e33`; CW, EW, SRTRW, TTW, TW).
- Each build's leave-one-season-out set is EW43–EW18 (28 files a season, 29 in 2014/15): 197 / 225 / 253 files per method.
- The 2017/18 and 2018/19 build trees also held 14 EW19/EW20 files per method last written on 2017-10-24 (`3e548b9`) and never rebuilt: stale, excluded (logged in `file-map-excluded.csv`). They caused the earlier 30-file `TRW_cv` seasons and a 0.05 gap in a 2011/12 non-week target.
- `_repaired` copies hold every file of the build: repaired leave-one-season-out files plus unchanged real-time files, so each is complete on its own.

## Hub layout

```
hub-config/            admin.json, tasks.json, model-metadata-schema.json, target-data.json (schema v6.0.0)
model-output/<model_id>/<origin_date>-<model_id>.parquet
model-metadata/<model_id>.yml       # generated from source metadata.txt; adds real_time_start_season, is_ensemble, cv flag
target-data/time-series.parquet     # observed wILI by location × week
target-data/oracle-output.parquet   # pmf + median oracle rows
auxiliary-data/
  original-point-forecasts/         # the source Point rows, unchanged
  point-vs-pmf-median.csv           # per-model check of how the reported points relate to the pmf
  wili-baselines.csv, ensemble-weights/, model-id-map.csv
  file-provenance.csv               # per converted file: source path, commit, first-commit date, delay, record, duplicate_of, later edits
  ensemble-training-sets.csv        # which model IDs × seasons trained each real-time ensemble season
excluded_output/                    # every excluded row, with a reason column
validation/                         # manifests, reconciliation tables, reports (committed)
src/                                # numbered pipeline scripts + tests
```

## Pipeline (`src/`, run in order, each step idempotent)

| # | Script | Output |
|---|---|---|
| 01 | `manifest` | Full clone of the source with all branches, tags and history. List every forecast-file version: path, blob sha, commit, date and branches containing it (extends `validation/source-history.csv`). |
| 02 | `file_map` | One row per **chosen version** of each file: collection, source model, `model_id` (with suffix), record (real-time / training) plus evidence, `duplicate_of`, season, source `EWxx-YYYY`, `origin_date`, output path, and keep/drop status with a reason. Reasons include submission duplicates, same-week resubmissions, impossible week names, moved duplicates, and superseded or removed-and-not-kept versions. |
| 03 | `standardise` | Read each file, lowercase the headers, canonicalise labels and write intermediate parquet. Values are not touched. |
| 04–06 | `convert` (one script, `src/04_convert.R`) | Per file: sum checks, renormalisation, exclusions and change log (04); medians from the cleaned pmfs (05); one parquet file per model × round (06). Points kept for `auxiliary-data/`. |
| 07 | `metadata` | `model-metadata/*.yml` (including `forecast_mode` and paired IDs), `file-provenance.csv`, `ensemble-training-sets.csv`. |
| 08 | `target_data` | `time-series` and `oracle-output` (see below). |
| 09 | `config` | `tasks.json` etc., generated from the data and then reviewed by hand. |
| 10 | `validate` | All checks below. Writes `validation/report.md`. |

### Target data
- **time-series**: weekly observed wILI (one decimal) per location, taken from `scores/zoltar_truths_all_seasons.csv`. Optionally cross-checked against Delphi Epidata, as a check only.
- **oracle-output**, built from `scores/target-multivals.csv` and the Zoltar truths:
  - pmf rows: 1 for the observed bin, 0 for every other bin, exactly one 1 per forecast. Tied peak weeks are handled as decided in Phase 4.
  - Weekly `ili perc` rows are keyed by `target_end_date`, `location` and `target`. Seasonal target rows are keyed by `origin_date`, `location` and `target`, so each season's truth repeats for every `origin_date` in that season.
  - median rows (weekly `ili perc` only): `oracle_value` = the observed value.

## Checks

1. **Round-trip test (all 82.7M rows).** Rebuild each kept source file from the hubverse output plus the change log and `auxiliary-data/`. Require:
   - every source row maps to exactly one output row, or one excluded row;
   - unchanged values are bit-identical;
   - renormalised values equal the source value divided by the logged sum, within 1e-12;
   - original points match their source rows exactly.
2. **Row accounting.** For each source file: rows in = kept + renormalised + excluded + dropped duplicates. The table is committed.
3. **Per model × round checksums**, computed on both sides.
4. **hubverse checks:**
   - `hubAdmin::validate_hub_config()`;
   - `hubValidations::validate_submission()` on every file, run in parallel;
   - `validate_model_metadata()`;
   - `hubData::connect_hub() |> collect_hub()` completes, with the expected row counts per model.
5. **Quality report**, reported but not acted on: renormalisation counts per model, exclusions, medians in the 13+ bin, missing models/rounds per season.
6. **Downstream smoke tests**, on one season, in `src/tests/`:
   - `modelimportance::model_importance()` with pmf inputs (a weekly ILI target and a week target) and median inputs (weekly ILI);
   - on the 2017/18 real-time ensemble's components and the cv ensemble's `_train` components, to confirm the model ID split gives analyses the right model sets;
   - check: every `duplicate_of` pair is value-identical in the hub;
   - check: within each record, no forecast appears twice (no duplicates inside the real-time record or inside the training record).
   - `hubEvals::score_model_out()` log score;
   - this confirms the label canonicalisation and the one-1-per-forecast truth rule.
   - These tests will also hit the missing-`horizon` problem. Until hubEvals handles it, the workaround is to drop columns that are entirely empty after filtering to one target.
7. **Spot checks**: about 20 random forecasts plotted from the hub against the source CSV.

## Phases and checkpoints

| Phase | Work | Checkpoint with the user |
|---|---|---|
| 1 | Steps 01–03 | Review the file map: model IDs and suffixes, placement in the real-time / training records (especially the edge cases), duplicate counts, `component-models/` files edited after the 2019-10-25 pin (keep the pinned or the final version?), dropped/duplicate submissions, badly named files |
| 2 | Step 04 | **Review queue**, especially the cv-ensemble probability problem and whether it's a file-building bug |
| 3 | Steps 05–07, 09 | Review `tasks.json` and metadata |
| 4 | Step 08 | **The 14 tied peak weeks, one at a time**, with wILI values |
| 5 | Step 10 and the smoke tests | Validation report; decide whether to publish |
| 6 | Publish: README (conversion approach, changes, caveats), LICENSE (CC BY-NC-SA 4.0, inherited), push, optional S3 onboarding | File the hubEvals issue about missing task values |

## Downstream: alloscore2

alloscore2 only accepts quantiles, but internally it builds a CDF with `distfromq::make_p_fn(ps, qs)`. For binned ILI forecasts, the pairs (right edge of each bin, cumulative probability up to it) already give it that input. So adding `pmf`/`cdf` support to alloscore2 is preferable to storing derived quantiles in this archive. If quantiles are needed sooner, publish them as a separately labelled derived dataset, never in `model-output/`. Allocation scoring applies only to the weekly ILI targets across locations.

## Source history beyond master (found 2026-11-22)

The full git history across all branches and tags (`master`, `end-of-2018-2019-season` = `v.2.0`, `first-papers`, `v.1.0`, `gh-pages`) holds 37,361 distinct (path, content) versions of forecast files. Master has 10,305. The full catalogue is `validation/source-history.csv`.

- **Models removed from master but real** (mostly removed in Oct 2018: "removing LANL-DBM files from master branch", "removing UTaustin models…", "Update Delphi dev set forecasts for 2018/2019"):
  - Delphi `*_PackageDefaults` ×5, `Delphi_EmpiricalBayes_{PackageDefaults,Cond4}`, `Delphi_Stat_FewerComponentsNoBackcastNoNowcast`;
  - `LANL_DBM`, `UTAustin_edm`, `ReichLab_kcde`.
  - Each has retrospective forecasts for 2010/11–2017/18, plus 2017/18 real-time ones (and 2018/19 for `ReichLab_kcde`).
  - The 2017/18 real-time ensemble was built from the PackageDefaults versions and `ReichLab_kcde`; `models-for-2017-2018.csv` (2018-10-17) marks LANL_DBM and UTAustin_edm FALSE, but FSN's 2017/18 weights (commit 76d9a33) include LANL-DBM (and Delphi EmpiricalBayes1/2 and Stat), so they were components; UTAustin_edm was not (corrected 2026-11-23, `validation/ensemble-components.csv`).
- **Removed and not worth keeping:** `.ipynb_checkpoints`; `ReichLab_kcde_backfill_post-hoc` (replaced the next day by `_post_hoc`); `CUEAKFC` (an early name, replaced by the 6 CU models within a week); `Delphi_DeltaDensity` (17 files, all identical to files still in master).
- **Removed, but included by decision:** `FluSight_unweighted_avg` (85 files, 2015/16–2017/18, CDC's own unweighted-average ensemble); `cv-ensemble-models/target-and-region-based-weights` (239 files, removed 2019-10-25 as "old").
- **Superseded versions:** 16,468 older versions of files that are still in master. Mostly retrospective re-runs (cv ensembles recomputed in 2017–18, Protea, CU, FluX, kcde).
  - 18 are **real-time 2019/20 files changed after submission** (Protea_Kudu ×3, FluOutlook ×4, real-time ensembles ×9, CUBMA ×1, kcde ×1).

## Open items

- **Downstream findings from the modelimportance smoke test** (`src/11_smoke_modelimportance.R`, passing):
  - hubEvals/scoringutils drop rows with NA task IDs → drop all-NA `horizon`/`target_end_date` before scoring seasonal targets (file hubEvals issue once the hub is live).
  - modelimportance renames `origin_date` → `reference_date` in forecasts but not in `oracle_output_data` → rename the oracle column too (worth reporting to modelimportance).

- **Badly named files** (Phase 1 review):
  - `real-time-component-models/CUBMA/EW63-2019-CUBMA.csv`: week 63 doesn't exist. CUBMA already has every week 40–52 and 01–13, and this file differs from EW43. Find which week it matches, or exclude it.
  - `real-time-component-models/ReichLab_kde/EW21-2020-ReichLab_kde.csv`: one week past the usual EW20 season end. Keep it, and include the round in `tasks.json`.
  - About 30 files per real-time season were first committed **before** their forecast date (e.g. ReichLab_kde 2019/20, median −94 days). Most likely a wrong year in the file name (`EW40-2020` for `EW40-2019`). Confirm against content, fix the round, and log it.
  - Historical names such as `EW002-2020-*` (CU, later renamed) and `UTAustin_edm/EW01_2010_*`.
- 15–60-day delays (about 22 files per season): classify by the `real-time-component-models/` path rule. Review any that conflict with commit timing.
- Whether the cv-ensemble week-target sums come from the bin-label bug, and if so, whether to exclude those forecasts or rebuild them from components plus `weights/`.
- Whether a `"none"` label passes validation for an onset target with `target_type: "date"`. If not, use `target_type: "nominal"` for onset.
- Model ID spelling for each component model, from `model-id-map.csv`, checked against the hubverse `team-model` pattern.
- The 14 tied peak-week cases.
