# Step 07: model metadata, auxiliary data and change/exclusion logs.
#
# Outputs (committed):
#   model-metadata/<model_id>.yml
#   auxiliary-data/original-point-forecasts.parquet   source Point rows, unchanged
#   auxiliary-data/file-provenance.csv                one row per model-output file (with is_real_time)
#   auxiliary-data/superseded-forecasts.parquet       training versions replaced by a different real-time version
#   validation/ensemble-components.csv                FSN ensemble components per operational season
#   excluded_output/excluded-forecasts.parquet         every excluded pmf row, with reason
#   validation/changes.parquet                        every renormalised/excluded forecast
#   validation/conversion-stats.csv                   per-file row accounting

source("src/00_config.R")
suppressPackageStartupMessages({ library(arrow); library(yaml) })

fm <- load_file_map()
ids <- fread(file.path(SRC_DIR, "model_ids.csv"), na.strings = "")
CV_DIR <- file.path(WORK_DIR, "convert")
for (d in c("model-metadata", "auxiliary-data", "excluded_output")) dir.create(file.path(REPO_ROOT, d), showWarnings = FALSE)

# ---- combine per-file logs ----------------------------------------------------------------------
combine <- function(sub) {
  fs <- list.files(file.path(CV_DIR, sub), full.names = TRUE)
  rbindlist(lapply(fs, function(f) as.data.table(read_parquet(f))), fill = TRUE)
}
stats <- combine("stats"); changes <- combine("changes"); excluded <- combine("excluded"); points <- combine("points")
stopifnot(nrow(stats) == nrow(fm))
points <- merge(points, fm[, .(model_id, origin_date = as.Date(origin_date), record)], by = c("model_id", "origin_date"))
setorder(points, model_id, origin_date, source_row)
write_parquet(points, file.path(REPO_ROOT, "auxiliary-data", "original-point-forecasts.parquet"))
setorder(excluded, model_id, origin_date, source_row)
write_parquet(excluded, file.path(REPO_ROOT, "excluded_output", "excluded-forecasts.parquet"))
setorder(changes, model_id, origin_date, location, target)
write_parquet(changes, file.path(VALIDATION_DIR, "changes.parquet"))
fwrite_csv(stats, "conversion-stats.csv")

prov <- fm[, .(model_id, record, is_real_time, origin_date, season, output_file, source_repo, source_path = path, source_blob = blob,
               source_commit = commit, source_author_date = author_date, selection, lag_days,
               week_rolled_over, year_corrected, from_unmerged_pr, duplicate_of)]
prov[, source_file := basename(source_path)]
fwrite(prov, file.path(REPO_ROOT, "auxiliary-data", "file-provenance.csv"))
message("wrote auxiliary-data/file-provenance.csv (", nrow(prov), " rows)")

# ---- superseded training versions: kept unchanged (standardised source rows) ----------------------------
sup <- fread(file.path(VALIDATION_DIR, "file-map-superseded.csv"))
sup_rows <- rbindlist(lapply(seq_len(nrow(sup)), function(i) {
  d <- as.data.table(read_parquet(file.path(WORK_DIR, "std", paste0(sup$blob[i], ".parquet"))))
  d[, .(model_id = sup$model_id[i], origin_date = as.Date(sup$origin_date[i]), location, target, type, unit,
        bin_start_raw, bin_end_raw, value_raw, value, source_row = row_id, source_path = sup$path[i], source_blob = sup$blob[i],
        replaced_by_blob = sup$replaced_by_blob[i])]
}))
write_parquet(sup_rows, file.path(REPO_ROOT, "auxiliary-data", "superseded-forecasts.parquet"))
message("wrote auxiliary-data/superseded-forecasts.parquet (", nrow(sup), " files, ", nrow(sup_rows), " rows)")

# ---- FSN ensemble components per operational season (from FSN's weights at each build) -----------------
vers <- fread(file.path(SRC_DIR, "model_versions.csv"))
v_rt <- vers[, .(season = strsplit(real_time_seasons, ";", fixed = TRUE)[[1]]), by = .(dir, version_id)]
builds <- fread(file.path(SRC_DIR, "ensemble_builds.csv"))
WEIGHT_BUILDS <- setNames(builds$weights_commit, builds$season)
ens_comp <- rbindlist(lapply(names(WEIGHT_BUILDS), function(s) {
  c0 <- WEIGHT_BUILDS[[s]]
  w <- fread(text = git("show", paste0(c0, ":weights/constant-weights.csv")))
  idm <- fread(text = git("show", paste0(c0, ":model-forecasts/component-models/model-id-map.csv")))
  setnames(idm, c("fsn_id", "dir", "complete")[seq_along(names(idm))])
  data.table(season = s, fsn_id = unique(w$component_model_id))[idm, on = "fsn_id", dir := i.dir][, build_commit := c0]
}))
ens_comp[, model_id := ids[match(ens_comp$dir, ids$dir), realtime_id]]
ens_comp[v_rt, on = .(dir, season), model_id := i.version_id]
stopifnot(!anyNA(ens_comp$model_id), all(ens_comp$model_id %in% fm$model_id))
fwrite_csv(ens_comp[, .(season, fsn_component_id = fsn_id, source_dir = dir, model_id, build_commit)], "ensemble-components.csv")

# ---- model metadata ----------------------------------------------------------------------------------
meta_txt <- function(collection, dir) {
  p <- sprintf("model-forecasts/%s/%s/metadata.txt", collection, dir)
  c1 <- tryCatch(git("rev-list", "-n", "1", "--branches", "--tags", "--", p), error = function(e) character())
  if (!length(c1)) return(NULL)
  txt <- tryCatch(git("show", paste0(c1, ":", p)), error = function(e)
    tryCatch(git("show", paste0(c1, "^:", p)), error = function(e) NULL))
  if (is.null(txt)) return(NULL)
  tryCatch(yaml.load(paste(txt, collapse = "\n")), error = function(e) NULL)
}

src_dirs <- unique(fm[, .(model_id, dir_key, path, source_repo)])
src_dirs[, fsn := source_repo == SOURCE_URL]
src_dirs[fsn == TRUE, `:=`(collection = tstrsplit(path, "/", fixed = TRUE)[[2]], dir = sub("^model-forecasts/[^/]+/", "", dirname(path)))]
src_dirs[fsn == FALSE, `:=`(collection = NA_character_, dir = paste0(sub("^https://github.com/", "", source_repo), ": ", dirname(path)))]
src_dirs[, label := fifelse(fsn, paste0(collection, "/", dir), dir)]

pair_of <- function(id) {
  if (endsWith(id, "_repaired")) return(sub("_repaired$", "", id))
  if (startsWith(id, "FSNetwork-") && paste0(id, "_repaired") %in% fm$model_id) return(paste0(id, "_repaired"))
  NULL
}
# ensemble FSN submitted to CDC as "FluSight-Network" each season
SUBMITTED <- c("2017_18" = "TTW", "2018_19" = "TW", "2019_20" = "TTW")
seasons_of <- function(x) as.list(sort(unique(x)))

write_meta <- function(id) {
  x <- src_dirs[model_id == id]
  f <- fm[model_id == id]
  is_rep <- endsWith(id, "_repaired"); is_ens <- startsWith(id, "FSNetwork-")
  tag <- if (is_ens) sub("^FSNetwork-[A-Z]+_([0-9]{4}_[0-9]{2}).*$", "\\1", id) else NA
  b <- if (is_ens) builds[match(tag, builds$tag)] else NULL
  vv <- vers[version_id == id]
  m <- NULL
  for (k in which(x$fsn)) { m <- meta_txt(x$collection[k], x$dir[k]); if (!is.null(m)) break }
  if (is.null(m)) { cand <- unique(x$dir_key); for (cl in c("component-models", "real-time-component-models",
                    "cv-ensemble-models", "real-time-ensemble-models")) for (dd in cand) if (is.null(m)) m <- meta_txt(cl, dd) }
  parts <- strsplit(id, "-", fixed = TRUE)[[1]]
  note <- ids[dir %in% x$dir_key, paste(unique(na.omit(note)), collapse = "; ")]
  members <- if (!is.null(m$team_members)) trimws(strsplit(gsub("'", "", m$team_members), ",")[[1]]) else character()
  n_late <- f[record == "late", .N]; n_rt <- f[is_real_time == TRUE, .N]
  kind_note <- if (is_ens) paste0(b$note, " This model ID holds that build: the leave-one-season-out forecasts (not real-time) and FSN's ",
                                  b$season, " real-time forecasts made with the same method",
                                  if (SUBMITTED[[tag]] == sub("^FSNetwork-([A-Z]+)_.*$", "\\1", id))
                                    paste0(" (FSN's ", b$season, " submission to CDC as FluSight-Network; where they differ, the submitted file is used)") else "",
                                  ". Components and weights: validation/ensemble-components.csv and FSN's weights/ at the build commit.")
    else paste0("One model ID holding every round of this model: ", n_rt, " real-time forecasts and ",
                nrow(f) - n_rt, " forecasts not made in real time (FSN training backcasts",
                if (n_late) paste0(", and ", n_late, " real-time-folder files committed after the cutoff") else "",
                "). The per-round flag is is_real_time in auxiliary-data/file-provenance.csv.")
  out <- list(
    team_abbr = parts[1], model_abbr = parts[2],
    team_name = m$team_name %||% NA, model_name = m$model_name %||% NA,
    model_contributors = lapply(members, function(n) list(name = n)),
    real_time_seasons = seasons_of(f[is_real_time == TRUE, season]),
    fsn_ensemble_component_seasons = if (!is_ens && nrow(ens_comp[model_id == id])) seasons_of(ens_comp[model_id == id, season]) else NULL,
    version_of = if (nrow(vv)) ids[dir == vv$dir, realtime_id] else NULL,
    version_note = if (nrow(vv)) vv$version_note else NULL,
    paired_model_id = pair_of(id),
    source_dirs = as.list(sort(unique(x$label))),
    seasons = seasons_of(f$season),
    this_model_is_an_ensemble = isTRUE(as.logical(m$this_model_is_an_ensemble)),
    real_time_start_season = if (is.null(m$real_time_start_season)) NULL else as.character(m$real_time_start_season),
    methods = if (is.null(m$methods)) NULL else trimws(m$methods),
    data_inputs = paste(na.omit(unlist(m[c("data_source1", "data_source2")])), collapse = ", "),
    designated_model = FALSE,
    notes = paste(c(if (nzchar(note)) note,
                    if (is_rep) paste("REPAIRED copy of", sub("_repaired$", "", id), "(user decision 2026-11-23: keep original and revised).",
                                      "FSN's stacking code joined component bins on start AND end, so where components label the last week of the year",
                                      "differently (week 52, or 53 in 2014/15: [52, 1) vs [52, 53)) some components' probability for that bin was dropped.",
                                      "In the affected leave-one-season-out files only that bin is recomputed, from FSN's own components and weights;",
                                      "every other value, and every real-time file, is identical to the original (see validation/cv-repair.csv)."),
                    kind_note,
                    if (id == "FluSight-unweighted_avg") paste("CDC's unweighted average of FluSight submissions. 2015/16-2017/18 from FSN's copies;",
                      "2018/19-2019/20 from CDC's originals in cdcepi/FluSight-forecasts (CC BY 4.0). FSN's 2016/17-2017/18 copies are",
                      "byte-identical to CDC's; FSN's 2015/16 copies use the one-decimal bins, unlike CDC's 2015/16 originals.")),
                  collapse = " "))
  out <- Filter(function(v) !is.null(v) && !(length(v) == 1 && is.na(v)), out)
  write_yaml(out, file.path(REPO_ROOT, "model-metadata", paste0(id, ".yml")), handlers = list(
    logical = function(v) { r <- ifelse(v, "true", "false"); class(r) <- "verbatim"; r }))
  data.table(model_id = id, has_source_metadata = !is.null(m))
}
`%||%` <- function(a, b) if (is.null(a)) b else a
unlink(list.files(file.path(REPO_ROOT, "model-metadata"), pattern = "\\.yml$", full.names = TRUE))
mm <- rbindlist(lapply(sort(unique(fm$model_id)), write_meta))
cat("model metadata files:", nrow(mm), " without source metadata.txt:", mm[has_source_metadata == FALSE, .N], "\n")
print(mm[has_source_metadata == FALSE])
