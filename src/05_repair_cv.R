# Step 05: build repaired copies of the cv ensembles (user decision 2026-11-23: keep original AND revised).
#
# FSN's scripts/stack_forecasts.R joined component files on bin start AND end. CU-BMA (the first
# component) writes the week-52 bin as [52, 1); most models write [52, 53). So every other model's
# week-52 probability was dropped from the onset / peak-week forecasts of every cv ensemble.
#
# Repair: for each cv file, rebuild the week-target bins from the components and weights that FSN
# used (the source tree at the commit that created that cv file), matching bins on their start week
# only. Then replace ONLY the week-52 bin values in FSN's file. Every other value is left exactly as
# FSN committed it; the script checks that the rebuild reproduces those other values (<= 1e-12).
#
# Outputs:
#   .cache/work/std/repaired-<blob>.parquet       repaired standardised tables (input to step 04)
#   validation/file-map-repaired.csv               file-map rows for FSNetwork-<ABBR>_cv_repaired
#   validation/cv-repair.csv                       per-file repair report
#   validation/cv-repair-values.parquet            every changed value: original vs repaired

source("src/00_config.R")
suppressPackageStartupMessages({ library(arrow); library(parallel) })

fm <- fread(file.path(VALIDATION_DIR, "file-map.csv"))
cv <- fm[record == "cross-validated"]
STD_DIR <- file.path(WORK_DIR, "std")
WEEK_TARGETS <- c("Season onset", "Season peak week")
NONMATCH_TOL <- 1e-12

show_csv <- function(commit, path) {
  txt <- tryCatch(git("show", paste0(commit, ":", path)), error = function(e) NULL)
  if (is.null(txt)) NULL else fread(text = txt, colClasses = "character")
}
cache <- new.env()
cached <- function(commit, path) {
  k <- paste(commit, path); if (!exists(k, cache)) assign(k, show_csv(commit, path), cache); get(k, cache)
}

rebuild_week_bins <- function(commit, ens_dir, week, ssn) {
  ids <- cached(commit, "model-forecasts/component-models/model-id-map.csv")
  setnames(ids, c("model_id", "model_dir", "complete")[seq_along(names(ids))])
  # FSN sometimes committed the weights a minute AFTER the ensemble files built from them
  # (e.g. TRW, 2018-10-23 15:46 files / 15:47 weights): use a weights commit within 1 hour after.
  wpath <- sprintf("weights/%s.csv", ens_dir)
  t_build <- as.numeric(git("show", "-s", "--format=%ct", commit))
  wc <- git("log", "--branches", "--format=%H %ct", "--", wpath)
  wc <- if (length(wc)) data.table(h = sub(" .*", "", wc), t = as.numeric(sub(".* ", "", wc))) else data.table(h = character(), t = numeric())
  later <- wc[t > t_build & t <= t_build + 3600][order(t)]
  wcommit <- if (nrow(later)) later$h[1] else commit
  w <- copy(cached(wcommit, wpath))
  if (is.null(w)) stop("weights file not found at build commit: weights/", ens_dir, ".csv")
  w[, weight := as.numeric(weight)]
  w <- w[season == ssn]
  jw <- intersect(c("component_model_id", "target", "location"), names(w))
  parts <- lapply(seq_len(nrow(ids)), function(i) {
    e <- show_csv(commit, sprintf("model-forecasts/component-models/%s/%s-%s.csv", ids$model_dir[i], week, ids$model_dir[i]))
    if (is.null(e)) return(NULL)
    setnames(e, tolower(names(e)))
    e <- e[trimws(type) == "Bin" & trimws(target) %in% WEEK_TARGETS]
    e[, `:=`(location = trimws(location), target = trimws(target), component_model_id = ids$model_id[i],
             value = as.numeric(value))]
    b <- trimws(e$bin_start_incl)
    e[, bin_label := ifelse(b == "none", "none", as.character(as.integer(round(as.numeric(b)))))]
    merge(e, w[, c(jw, "weight"), with = FALSE], by = jw, all.x = TRUE)
  })
  parts <- rbindlist(Filter(Negate(is.null), parts), fill = TRUE)
  list(n_components = uniqueN(parts$component_model_id), weights_commit = wcommit,
       missing_weights = parts[is.na(weight), uniqueN(component_model_id)],
       bins = parts[, .(rebuilt = sum(weight * value, na.rm = TRUE)), by = .(location, target, bin_label)])
}

repair_one <- function(i) {
  r <- cv[i]
  week <- sub("^(EW[0-9]+-[0-9]{4}).*$", "\\1", basename(r$path))
  rb <- rebuild_week_bins(r$commit, r$dir_key, week, r$season)
  d <- as.data.table(read_parquet(file.path(STD_DIR, paste0(r$blob, ".parquet"))))
  wk <- d[type == "Bin" & target %in% WEEK_TARGETS, .(row_id, location, target, bin_label, value)]
  m <- merge(wk, rb$bins, by = c("location", "target", "bin_label"), all.x = TRUE)
  last_wk <- as.character(mmwr_weeks_in_year(as.integer(substr(r$season, 1, 4))))
  other <- m[bin_label != last_wk]
  max_other <- max(abs(other$value - other$rebuilt), na.rm = TRUE)
  fix <- m[bin_label == last_wk]
  ok <- is.finite(max_other) && max_other <= NONMATCH_TOL && !anyNA(fix$rebuilt) && rb$missing_weights == 0
  rep <- data.table(model_id = r$model_id, origin_date = as.Date(r$origin_date), blob = r$blob, build_commit = r$commit,
                    week = week, repaired_bin = last_wk, weights_commit = rb$weights_commit, n_components = rb$n_components, components_missing_weights = rb$missing_weights,
                    max_abs_diff_other_bins = max_other, repaired_rows = nrow(fix),
                    max_added_mass = max(fix$rebuilt - fix$value), repaired = ok)
  if (!ok) return(list(report = rep, values = NULL))
  d2 <- copy(d)
  d2[fix, on = "row_id", `:=`(value = i.rebuilt, value_raw = paste0("repaired:", format(i.rebuilt, digits = 17)))]
  write_parquet(d2, file.path(STD_DIR, paste0("repaired-", r$blob, ".parquet")))
  list(report = rep, values = fix[, .(model_id = r$model_id, origin_date = as.Date(r$origin_date), location, target,
                                      bin_label, original = value, repaired = rebuilt)])
}

t0 <- Sys.time()
res <- mclapply(seq_len(nrow(cv)), function(i) tryCatch(repair_one(i), error = function(e)
  list(report = data.table(model_id = cv$model_id[i], origin_date = as.Date(cv$origin_date[i]), error = conditionMessage(e),
                           repaired = FALSE), values = NULL)), mc.cores = max(1L, detectCores() - 2L))
message("repaired in ", round(difftime(Sys.time(), t0, units = "mins"), 1), " min")
report <- rbindlist(lapply(res, `[[`, "report"), fill = TRUE)
values <- rbindlist(lapply(res, `[[`, "values"))
fwrite_csv(report, "cv-repair.csv")
write_parquet(values, file.path(VALIDATION_DIR, "cv-repair-values.parquet"))

fmr <- merge(cv, report[repaired == TRUE, .(model_id, origin_date = as.IDate(origin_date))], by = c("model_id", "origin_date"))
fmr[, `:=`(model_id = paste0(model_id, "_repaired"), blob = paste0("repaired-", blob),
           selection = paste(selection, "+ week-52 bin repaired (src/05_repair_cv.R)"),
           duplicate_of = NA_character_)]
fmr[, output_file := sprintf("model-output/%s/%s-%s.parquet", model_id, origin_date, model_id)]
fwrite_csv(fmr, "file-map-repaired.csv")

cat("\n=== cv repair ===\n")
print(report[, .(files = .N, repaired = sum(repaired, na.rm = TRUE), not_repaired = sum(!repaired, na.rm = TRUE),
                 max_diff_other_bins = max(max_abs_diff_other_bins, na.rm = TRUE),
                 max_added_mass = max(max_added_mass, na.rm = TRUE)), by = .(ensemble = sub("_cv$", "", model_id))])
if ("error" %in% names(report)) print(report[!is.na(error), .N, by = error])
print(head(report[repaired == FALSE], 10))
