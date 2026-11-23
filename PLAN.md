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
| Real-time vs training | Separated **by model ID suffix**, mirroring FSN's two records (see "Two records" below). Plain ID = real-time submissions as submitted; `_train` = the full training series from `component-models/`, pinned to the 2019-10-25 cv build, including flagged duplicates of real-time files; `_cv` = leave-one-season-out ensembles. |
| Ensemble model IDs | Real-time: `FSNetwork-<ABBR>`. Cross-validated: `FSNetwork-<ABBR>_cv`. |
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
| Delphi PackageDefaults *(Phase 1)* | **Separate IDs**: `Delphi-<model>_PD` (real-time 2017/18) and `Delphi-<model>_PD_train`. |
| kcde_backfill re-run *(Phase 1)* | `ReichLab-KCDE_NB_train` / `_PHB_train` use the **final (re-run) version** committed 2019-10-26, not the pinned one, even though FSN's scores, weights and cv ensembles were built from the pinned files. Logged as an exception to the pin. |
| Week numbers past 52 *(Phase 1)* | CU's `EW53-2017` … `EW65-2019` names roll over into the next year (EW53-2017 = EW01-2018). Every rolled-over file is identical to its correctly named copy where one exists. |
| Hub identity *(Phase 1)* | Not decided yet: `admin.json` holds PLACEHOLDER values; no S3/cloud. |
| cv-ensemble sums *(Phase 1)* | Diagnosed (`src/diag_cv_ensembles.R`): FSN's `stack_forecasts()` joined components on bin start **and** end; CU-BMA (first component) writes the week-52 bin as [52, 1) while most models write [52, 53), so other models' week-52 probability was dropped from every cv ensemble. Explains all 6,291 cv forecasts off by more than 0.1 (all week targets). **Repair (option c): decision pending.** Until then these forecasts are excluded by the 0.1 rule. |

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

## Two records: real-time and training

The archive mirrors the two records FSN itself kept. A forecast that belongs to both appears in both, as a flagged byte-identical duplicate.

**Why we duplicate.** FSN's training data was never purely retrospective:
- All cv-ensemble files for 2010/11–2018/19 were rebuilt in one commit on **2019-10-25**, from `component-models/` as it stood then.
- The 2019/20 real-time weights (`weights/`, the "prospective season" in `scripts/calculate-weights.R`) came from scores of those same files.
- At that point `component-models/` held backcasts for 2010/11–2016/17. For 2017/18 and 2018/19 it held the real-time files moved in at season end (`move-last-years-files.R`), and a backcast only where a model hadn't run in real time.

A backcast-only series would therefore have holes exactly where the ensembles used real-time files.

**Model IDs:**

| Model ID | Record | Contents |
|---|---|---|
| `<team>-<model>` | Real-time | Every forecast submitted in real time, **exactly as submitted** (2017/18–2019/20) |
| `<team>-<model>_train` | Training | The model's full 2010/11–2018/19 series as held in `component-models/`: backcasts plus the real-time files FSN moved in |
| `FSNetwork-<ABBR>` | Real-time | Real-time ensembles (including the 2017/18 and 2018/19 archives) |
| `FSNetwork-<ABBR>_cv` | Training | Leave-one-season-out ensembles; their components are exactly the `_train` IDs |

- **Which version `_train` holds:** the version in `component-models/` at the 2019-10-25 cv-build commit, i.e. the data the cv ensembles and 2019/20 weights were built from. Some files were edited afterwards (latest 2019-11-12). Those edits are logged and listed for review in Phase 1, and you decide there whether to use the final versions instead.
- **Models removed from master** (Delphi `PackageDefaults`/EmpiricalBayes/Stat, LANL_DBM, UTAustin_edm, ReichLab_kcde): `_train` holds their `component-models/` record as last present before removal. That is the training data for the 2017/18 and 2018/19 ensembles.
- **Models whose real-time participation started in 2019/20** (FluOutlook, FluX, UA_EpiCos, kcde_backfill_*): `_train` holds pure backcasts. Their real-time record is 2019/20 only.
- **Different model versions keep separate IDs.** For example, Delphi `PackageDefaults` (2017/18 real-time) vs the Delphi 2018 re-runs; ReichLab `kcde` vs `kcde_backfill_{none,post_hoc}`. Exact names are reviewed in Phase 1.
- **Exception — `FluSight_unweighted_avg`.** This is a copy of CDC's real-time FluSight ensemble, committed late (median 273 days). It is not an FSN component, so it gets only a plain real-time ID. Its metadata explains why.

**How each file is placed:**
- **Real-time record:** files that appeared in `real-time-component-models/`, `real-time-ensemble-models/` or `submissions/` during their season, at the version present at submission. Commit timing confirms the split independently: real-time files arrived within about 14 days of their forecast date, backcasts 61+ days later (mostly over a year).
- **Training record:** the pinned state of `component-models/` (and `cv-ensemble-models/`), plus removed models at their last state.
- **Duplicates:** a training file is matched by content against the real-time record. About 1,160 files (~9M rows) are expected to match. Matches are recorded in `duplicate_of` and verified byte-identical. Some matches cross model names: master's `Delphi_BasisRegression/EW05-2018` is the real-time `Delphi_BasisRegression_PackageDefaults` submission (367 such cases).
- **Training files that differ from the real-time submission** for the same model and round, because the copy was overwritten after moving, are kept as they are in `_train`. The difference is logged.

**Rule for users** (written into the README and every model's metadata): **never combine plain and `_train`/`_cv` IDs in one analysis.** Doing so counts the same forecasts twice. Use plain IDs for real-time evaluation, and `_train` + `_cv` for training and cross-validation work.

**Supporting records:**
- **Model metadata** for each ID records `forecast_mode` (`real-time` / `training` / `cross-validated`), the seasons covered, the paired ID (e.g. `ReichLab-KDE` ↔ `ReichLab-KDE_train`), the source directories and the pinned commit.
- **`auxiliary-data/file-provenance.csv`**: one row per converted file, with the source path, git commit, first-commit date, delay in days, record, `duplicate_of`, and edits made after the pin or after submission.
- **`auxiliary-data/ensemble-training-sets.csv`**: which `_train` IDs and seasons trained each real-time ensemble season.
  - **Known limitation:** the 2017/18 and 2018/19 ensembles were trained on earlier states of `component-models/`, and some backcasts were revised later (Protea, CU, Delphi). The table notes each place where the archived `_train` version differs from what an ensemble saw. Those exact earlier versions remain in git history (`validation/source-history.csv`) and could be converted later as separate IDs if needed.

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
  - The 2017/18 real-time ensemble was built from the PackageDefaults versions and `ReichLab_kcde`; `models-for-2017-2018.csv` marks LANL_DBM and UTAustin_edm FALSE.
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
