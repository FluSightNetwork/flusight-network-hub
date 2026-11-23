# Step 02: decide which version of which source file becomes each hub model-output file.
#
# Two records (see PLAN.md, "Two records: real-time and training"):
#   real-time record  -> plain model IDs: the submitted file if one exists, else FSN's real-time file;
#                        last version committed by due date + 3 days; later-committed rounds are not real-time
#   training record   -> *_train / *_cv model IDs, component-models/ and cv-ensemble-models/
#                        as of the training pin (2019-10-25 cv rebuild); removed dirs at their last state
#
# Outputs (committed):
#   validation/file-map.csv              one row per (model_id, origin_date): the selected source version
#   validation/file-map-excluded.csv     source files/rounds that are not converted, with a reason
#   validation/file-map-nonselected.csv  every other version of a selected round, with a reason
#   validation/file-map-review.csv       items flagged for human review

source("src/00_config.R")
stopifnot_source()

hist <- fread(file.path(VALIDATION_DIR, "source-history.csv"),
              colClasses = list(character = c("author_date", "commit_date")))
pin <- fread(file.path(VALIDATION_DIR, "source-pin.csv"))
PIN <- pin[name == "training_pin", commit]
ids <- fread(file.path(SRC_DIR, "model_ids.csv"), na.strings = "")

# Real-time rule (user decision 2026-11-22): a file is real-time only if committed no more than
# 3 days after the submission due date. FluSight forecasts were due the Monday 9 days after the
# origin Saturday, so the cutoff is origin + 12 days. The last version committed by then is used.
DUE_DAYS <- 9L
GRACE_DAYS <- 3L
YEARFIX_MAX_LAG <- 60L   # a wrong-year file name is corrected only if the corrected lag is 0..60 days

# ---- classify paths -------------------------------------------------------------
classify <- function(dt) {
  dt[, dir_key := basename(dir)]
  dt[collection == "submissions-archive", dir_key := sub("^[0-9]{4}-[0-9]{4}-", "", dir_key)]
  dt[, tier := fcase(
    collection == "real-time-component-models", "rt_component",
    collection == "real-time-ensemble-models" & !grepl("^archive", dir), "rt_ensemble",
    collection == "real-time-ensemble-models", "rt_ensemble_archive",
    collection == "submissions" & !grepl("^archive", dir), "rt_submission",
    collection %in% c("submissions", "submissions-archive"), "rt_submission_archive",
    collection == "component-models", "train_component",
    collection == "cv-ensemble-models", "train_cv",
    default = "unknown")]
  dt[, date := as.Date(substr(author_date, 1, 10))]
  dt[]
}

# versions reachable only through unmerged pull requests (user decision: include real-time ones, flagged)
pr_only_blobs <- setdiff(hist[source_refs == "pull_only" & status != "D", blob],
                         hist[source_refs == "branches_tags", blob])
v <- classify(hist[status %in% c("A", "M") & (source_refs == "branches_tags" | blob %in% pr_only_blobs)])
stopifnot(v[tier == "unknown", .N] == 0)
v[, from_unmerged_pr := source_refs == "pull_only"]
pr_train_excl <- v[from_unmerged_pr == TRUE & !startsWith(tier, "rt_")]
v <- v[!(from_unmerged_pr == TRUE & !startsWith(tier, "rt_"))]
v <- merge(v, ids[, .(dir_key = dir, kind, realtime_id, train_id, include, id_note = note)],
           by = "dir_key", all.x = TRUE)
unmapped <- v[is.na(include), unique(dir_key)]
if (length(unmapped)) stop("dirs missing from src/model_ids.csv: ", paste(unmapped, collapse = ", "))

# ---- rounds -----------------------------------------------------------------------
# CU numbered weeks continuously past the end of the year (EW53-2017 = EW01-2018,
# EW63-2019 = EW11-2020). Roll such weeks over into the next MMWR year.
v[, week_rolled_over := FALSE]
v[!is.na(ew) & ew > mmwr_weeks_in_year(ew_year) & ew <= mmwr_weeks_in_year(ew_year) + 20L,
  `:=`(ew = ew - mmwr_weeks_in_year(ew_year), ew_year = ew_year + 1L, week_rolled_over = TRUE)]
v[, valid_week := !is.na(ew) & ew >= 1L & ew <= mmwr_weeks_in_year(ew_year)]
v[valid_week == TRUE, origin_date := mmwr_week_end(ew_year, ew)]

# wrong-year file names: path first committed long before its stated forecast date
path_first <- v[, .(first_date = min(date)), by = path]
v <- merge(v, path_first, by = "path")
v[, lag_days := as.integer(first_date - origin_date)]
v[, year_corrected := FALSE]
# (a) committed >7 days BEFORE the stated forecast date: try the previous year (any tier)
v[valid_week == TRUE & lag_days < -7L, `:=`(
  alt_origin = mmwr_week_end(ew_year - 1L, pmin(ew, mmwr_weeks_in_year(ew_year - 1L))))]
# (b) real-time files committed >300 days AFTER the stated date: try the next year
#     (training backcasts are legitimately committed years later, so they are never shifted forward)
#     archive copies are excluded: their first commit is when FSN moved them, not when they were made
v[valid_week == TRUE & tier %in% c("rt_component", "rt_ensemble", "rt_submission") &
    !grepl("archive", dir) & collection != "submissions-archive" & lag_days > 300L, `:=`(
  alt_origin = mmwr_week_end(ew_year + 1L, pmin(ew, mmwr_weeks_in_year(ew_year + 1L))))]
v[!is.na(alt_origin) & as.integer(first_date - alt_origin) %between% c(0L, YEARFIX_MAX_LAG),
  `:=`(origin_date = alt_origin, year_corrected = TRUE)]
# propagate a real-time correction to training copies of the same file (same name and content)
fixed <- unique(v[year_corrected == TRUE & startsWith(tier, "rt_"), .(file, blob, fixed_origin = origin_date)])
v <- merge(v, fixed, by = c("file", "blob"), all.x = TRUE)
v[!is.na(fixed_origin) & !startsWith(tier, "rt_"), `:=`(origin_date = fixed_origin, year_corrected = TRUE)]
v[, fixed_origin := NULL]
v[, lag_days := as.integer(first_date - origin_date)]
v[, alt_origin := NULL]
v[, season := season_of(origin_date)]

# ---- exclusions at the file level ---------------------------------------------------
excl <- rbind(
  v[include == FALSE, .(path, blob, tier, dir_key, reason = paste0("dir not converted: ", id_note))],
  v[include == TRUE & valid_week == FALSE, .(path, blob, tier, dir_key, reason = "invalid MMWR week in file name")],
  pr_train_excl[, .(path, blob, tier, dir_key = basename(dir), reason = "training-folder version only in an unmerged pull request")]
)
v <- v[include == TRUE & valid_week == TRUE]

# ---- REAL-TIME RECORD ---------------------------------------------------------------
rt <- v[startsWith(tier, "rt_") | dir_key == "FluSight_unweighted_avg"]
rt[, model_id := realtime_id]
# preference among eligible versions: the file submitted to CDC, then FSN's own real-time file
rt[, tier_rank := fcase(tier == "rt_submission", 1L,
                        tier %in% c("rt_component", "rt_ensemble"), 2L,
                        tier %in% c("rt_ensemble_archive", "rt_submission_archive"), 3L,
                        default = 4L)]
rt[, cutoff := origin_date + DUE_DAYS + GRACE_DAYS]
rt[, ts := as.numeric(as.POSIXct(substr(author_date, 1, 19), format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"))]

select_rt <- function(g) {
  if (g$dir_key[1] == "FluSight_unweighted_avg") {
    pick <- g[order(-ts)][1]
    pick[, selection := "provenance exception: copy of CDC real-time ensemble (last version)"]
    return(pick)
  }
  el <- g[date <= cutoff]
  if (!nrow(el)) return(NULL)
  best <- min(el$tier_rank)
  pick <- el[tier_rank == best][order(-ts)][1]
  pick[, selection := fifelse(best == 1L, "submitted file: last version by cutoff", "last version by cutoff")]
  pick
}
rt_sel <- rt[, select_rt(.SD), by = .(model_id, origin_date), .SDcols = names(rt)]
rt_sel[, record := "real-time"]

# rounds with no version committed by the cutoff are not real-time
rt_late <- fsetdiff(unique(rt[, .(model_id, origin_date)]), rt_sel[, .(model_id, origin_date)])
rt_late <- merge(rt_late, rt[, .(first_commit = min(date), path = path[which.min(date)], blob = blob[which.min(date)],
                                 tier = tier[1], dir_key = dir_key[1], cutoff = cutoff[1]), by = .(model_id, origin_date)],
                 by = c("model_id", "origin_date"))

# non-selected real-time versions
rt_ns <- merge(rt, rt_sel[, .(model_id, origin_date, sel_blob = blob, sel_path = path, sel_tier = tier_rank)],
               by = c("model_id", "origin_date"))[!(path == sel_path & blob == sel_blob)]
rt_ns[, reason := fcase(
  blob == sel_blob, "identical content to selected version",
  tier %in% c("rt_ensemble_archive", "rt_submission_archive"), "archive copy differs from selected version",
  date > cutoff, "committed after cutoff (due date + 3 days)",
  sel_tier == 1L & tier == "rt_ensemble", "FSN real-time ensemble file differs from submitted file",
  default = "earlier version superseded before cutoff")]

# ---- TRAINING RECORD ----------------------------------------------------------------
ls_tree <- function(commit, paths) {
  x <- git("ls-tree", "-r", commit, "--", paths)
  if (!length(x)) return(data.table(path = character(), blob = character()))
  data.table(blob = sub("^\\S+ \\S+ (\\S+)\t.*$", "\\1", x), path = sub("^[^\t]*\t", "", x))
}
pin_tree <- ls_tree(PIN, c("model-forecasts/component-models", "model-forecasts/cv-ensemble-models"))
pin_tree[, src := "pin"]
pin_tree_orig <- copy(pin_tree)

# Exceptions to the pin (user decision 2026-11-22): these dirs use their final master version.
# ReichLab kcde_backfill files were re-run on 2019-10-26 ("fix formatting errors"), after the
# scores, weights and cv ensembles were built from the pinned files.
TRAIN_USE_FINAL_DIRS <- c("ReichLab_kcde_backfill_none", "ReichLab_kcde_backfill_post_hoc")
final_paths <- paste0("model-forecasts/component-models/", TRAIN_USE_FINAL_DIRS)
final_tree <- ls_tree(SOURCE_MASTER_SHA, final_paths)
final_tree[, src := "final master version (exception to pin)"]
pin_tree <- rbind(pin_tree[!startsWith(path, paste0(final_paths[1], "/")) & !startsWith(path, paste0(final_paths[2], "/"))],
                  final_tree)

# dirs absent at the pin: take their last state (tree just before they were deleted)
train_dirs <- unique(v[tier %in% c("train_component", "train_cv"), .(collection, dir)])
pin_dirs <- unique(pin_tree[, .(dir = sub("^model-forecasts/[^/]+/", "", dirname(path)))])
gone_dirs <- train_dirs[!dir %in% pin_dirs$dir]
last_state <- rbindlist(lapply(seq_len(nrow(gone_dirs)), function(i) {
  p <- sprintf("model-forecasts/%s/%s", gone_dirs$collection[i], gone_dirs$dir[i])
  dels <- hist[status == "D" & source_refs == "branches_tags" & startsWith(path, paste0(p, "/"))]
  # commit that deleted the most files from this dir = the removal commit
  rm_commit <- dels[, .N, by = .(commit, commit_date)][order(-N, commit_date)][1, commit]
  if (!is.na(rm_commit)) {
    st <- ls_tree(paste0(rm_commit, "^"), p)
    st[, `:=`(src = "last state before removal", removal_commit = rm_commit)]
  } else {
    # never deleted (lives only on a side branch): state at the last commit that touched it
    last_c <- hist[source_refs == "branches_tags" & startsWith(path, paste0(p, "/"))][order(-commit_date)][1, commit]
    st <- ls_tree(last_c, p)
    st[, `:=`(src = "last state (side branch only)", removal_commit = NA_character_)]
  }
  st
}), fill = TRUE)

tr <- rbind(pin_tree, last_state, fill = TRUE)
tr <- tr[startsWith(basename(path), "EW") | grepl("EW0*[0-9]{1,2}[-_][0-9]{4}", basename(path))]
# attach parsed metadata from the history table (path+blob)
tr <- merge(tr, unique(v[, .(path, blob, collection, dir, dir_key, tier, ew, ew_year, origin_date,
                             season, year_corrected, week_rolled_over, first_date, lag_days, train_id, realtime_id, id_note)]),
            by = c("path", "blob"), all.x = TRUE)
tr_unmatched <- tr[is.na(origin_date)]   # excluded dirs / invalid weeks / not in history table
tr <- tr[!is.na(origin_date) & !is.na(train_id)]
tr[, model_id := train_id]
tr[, record := fifelse(tier == "train_cv", "cross-validated", "training")]
# commit/date of the selected blob at that path (first commit introducing it)
first_commit <- v[, .SD[which.min(date)], by = .(path, blob), .SDcols = c("commit", "author_date", "date")]
tr <- merge(tr, first_commit, by = c("path", "blob"), all.x = TRUE)
tr[, selection := fcase(src == "pin", "state at training pin", src %like% "exception", src, default = src)]

# within a model_id, two paths may map to the same round (renamed files): keep one, log the rest
tr[, n_paths := .N, by = .(model_id, origin_date)]
tr_dupround <- tr[n_paths > 1]
setorder(tr, model_id, origin_date, -date)
tr_sel <- tr[, .SD[1], by = .(model_id, origin_date)]

# ---- duplicates between records ---------------------------------------------------------
# a duplicate = identical content AND the same forecast date (Delphi-Uniform repeats identical
# content across different weeks, which is not a duplicate forecast)
rt_blobs <- rt_sel[, .(blob, origin_date, duplicate_of_model = model_id, duplicate_of_origin = origin_date)]
tr_sel <- merge(tr_sel, rt_blobs[!duplicated(rt_blobs[, .(blob, origin_date)])], by = c("blob", "origin_date"), all.x = TRUE)
tr_sel[, duplicate_of := fifelse(is.na(duplicate_of_model), NA_character_,
                                 paste0(duplicate_of_model, " ", duplicate_of_origin))]
# same model & round exists in the real-time record but content differs
base_rt_id <- function(train_model) sub("_(train|train2017|cv)$", "", train_model)
tr_sel[, rt_counterpart := fifelse(record == "cross-validated", NA_character_, base_rt_id(model_id))]
tr_sel <- merge(tr_sel, rt_sel[, .(rt_counterpart = model_id, origin_date, rt_blob = blob)],
                by = c("rt_counterpart", "origin_date"), all.x = TRUE)
tr_sel[, train_vs_realtime := fcase(
  record == "cross-validated" & !is.na(duplicate_of), "identical to a real-time file",
  record == "cross-validated", "not applicable (cv ensemble)",
  is.na(rt_blob), "no real-time file for this round",
  rt_blob == blob, "identical to real-time submission",
  !is.na(duplicate_of), "identical to a different real-time file",
  default = "differs from real-time submission")]

# ---- assemble file map ------------------------------------------------------------------
cols <- c("model_id", "record", "origin_date", "season", "path", "blob", "commit", "author_date", "week_rolled_over", "from_unmerged_pr",
          "tier", "dir_key", "selection", "year_corrected", "first_date", "lag_days")
fm <- rbind(
  rt_sel[, c(cols, "cutoff"), with = FALSE][, `:=`(duplicate_of = NA_character_, train_vs_realtime = NA_character_)],
  tr_sel[, from_unmerged_pr := FALSE][, c(cols, "duplicate_of", "train_vs_realtime"), with = FALSE], fill = TRUE)
fm[, output_file := sprintf("model-output/%s/%s-%s.parquet", model_id, origin_date, model_id)]
setorder(fm, record, model_id, origin_date)
stopifnot(!anyDuplicated(fm[, .(model_id, origin_date)]))
fwrite_csv(fm, "file-map.csv")

# ---- non-selected and excluded -----------------------------------------------------------
fwrite_csv(rt_ns[, .(model_id, origin_date, path, blob, author_date, tier, reason)], "file-map-nonselected.csv")
excl_all <- rbind(
  excl,
  rt_late[, .(path, blob, tier, dir_key, reason = "not real-time: first committed after cutoff (due date + 3 days)")],
  tr_unmatched[, .(path, blob, tier = NA_character_, dir_key = basename(dirname(path)),
                   reason = "training file not mapped (excluded dir or invalid week)")],
  tr_dupround[!paste(path, blob) %in% tr_sel[, paste(path, blob)],
              .(path, blob, tier, dir_key, reason = "renamed duplicate of another file for the same round")],
  fill = TRUE)
fwrite_csv(unique(excl_all), "file-map-excluded.csv")

# ---- review items -----------------------------------------------------------------------
master_tree <- ls_tree(SOURCE_MASTER_SHA, "model-forecasts/component-models")
pin_comp <- pin_tree_orig[startsWith(path, "model-forecasts/component-models/")]
post_pin <- merge(pin_comp[, .(path, pin_blob = blob)], master_tree[, .(path, master_blob = blob)],
                  by = "path", all = TRUE)[is.na(pin_blob) | is.na(master_blob) | pin_blob != master_blob]
post_pin <- post_pin[grepl("EW", basename(path))]
post_pin[, change := fcase(is.na(pin_blob), "added after pin", is.na(master_blob), "deleted after pin",
                           default = "edited after pin")]
post_pin[basename(dirname(path)) %in% TRAIN_USE_FINAL_DIRS, change := paste(change, "(final version used)")]
post_pin[!basename(dirname(path)) %in% TRAIN_USE_FINAL_DIRS, change := paste(change, "(pinned version used)")]

pr_only_blobs <- setdiff(hist[source_refs == "pull_only" & status != "D", blob],
                         hist[source_refs == "branches_tags", blob])

review <- rbind(
  fm[year_corrected == TRUE, .(item = "wrong year in file name (corrected)", model_id, origin_date, path,
                               detail = paste0("first committed ", first_date, "; lag after correction ", lag_days, " d"))],
  rt_ns[week_rolled_over == TRUE & reason != "identical content to selected version",
        .(item = "week-rolled-over file differs from selected version", model_id, origin_date, path, detail = reason)],
  fm[week_rolled_over == TRUE, .(item = "selected file has week number past year end (rolled over)", model_id,
                                 origin_date, path, detail = "")],
  rt_late[, .(item = "not real-time: first committed after cutoff (due date + 3 days)", model_id, origin_date, path,
              detail = paste0("first commit ", first_commit, ", ", as.integer(first_commit - origin_date), " d after origin"))],
  fm[from_unmerged_pr == TRUE, .(item = "real-time file from an unmerged pull request (included)", model_id, origin_date, path, detail = "")],
  fm[record != "real-time" & train_vs_realtime == "differs from real-time submission",
     .(item = "training file differs from real-time submission", model_id, origin_date, path, detail = blob)],
  rt_ns[reason == "FSN real-time ensemble file differs from submitted file",
        .(item = "FSN real-time ensemble file differs from submitted file (submitted file used)", model_id, origin_date, path, detail = blob)],
  rt_ns[reason == "committed after cutoff (due date + 3 days)",
        .(item = "real-time file edited after cutoff (not used)", model_id, origin_date, path, detail = as.character(author_date))],
  post_pin[, .(item = paste("component-models file", change), model_id = NA_character_, origin_date = as.Date(NA),
               path, detail = paste(pin_blob, "->", master_blob))],
  data.table(item = "blob only reachable via PR refs", model_id = NA_character_, origin_date = as.Date(NA),
             path = hist[blob %in% pr_only_blobs, path[1], by = blob]$V1, detail = pr_only_blobs),
  fill = TRUE)
fwrite_csv(review, "file-map-review.csv")

# ---- summary ------------------------------------------------------------------------------
cat("\n=== file map ===\n")
print(fm[, .(models = uniqueN(model_id), files = .N, seasons = paste(range(season), collapse = "–")), by = record])
cat("\ntraining files that duplicate a real-time file:", fm[!is.na(duplicate_of), .N], "\n")
print(fm[record != "real-time", .N, by = train_vs_realtime])
cat("\nreal-time selection:\n"); print(fm[record == "real-time", .N, by = selection])
cat("\nnon-selected real-time versions:\n"); print(rt_ns[, .N, by = reason])
cat("\nexcluded source files:\n"); print(unique(excl_all)[, .N, by = reason])
cat("\nreview items:\n"); print(review[, .N, by = item])
