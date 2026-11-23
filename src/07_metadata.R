# Step 07: model metadata, auxiliary data and change/exclusion logs.
#
# Outputs (committed):
#   model-metadata/<model_id>.yml
#   auxiliary-data/original-point-forecasts.parquet   source Point rows, unchanged
#   auxiliary-data/file-provenance.csv                one row per model-output file
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

prov <- fm[, .(model_id, record, origin_date, season, output_file, source_path = path, source_blob = blob,
               source_commit = commit, source_author_date = author_date, selection, lag_days,
               week_rolled_over, year_corrected, from_unmerged_pr, duplicate_of, train_vs_realtime)]
prov[, source_file := basename(source_path)]
fwrite(prov, file.path(REPO_ROOT, "auxiliary-data", "file-provenance.csv"))
message("wrote auxiliary-data/file-provenance.csv (", nrow(prov), " rows)")

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

src_dirs <- unique(fm[, .(model_id, record, dir_key, path)])
src_dirs[, collection := tstrsplit(path, "/", fixed = TRUE)[[2]]]
src_dirs[, dir := sub("^model-forecasts/[^/]+/", "", dirname(path))]

pair_of <- function(id, rec) {
  if (endsWith(id, "_cv_repaired")) return(sub("_repaired$", "", id))
  if (endsWith(id, "_cv") && paste0(id, "_repaired") %in% fm$model_id) return(paste0(id, "_repaired"))
  base <- sub("_(train|cv)$", "", id)
  cands <- if (rec == "real-time") c(paste0(base, "_train"), paste0(base, "_cv")) else base
  hit <- intersect(cands, unique(fm$model_id)); if (length(hit)) hit[1] else NULL
}

write_meta <- function(id) {
  x <- src_dirs[model_id == id]
  rec <- x$record[1]
  is_rep <- endsWith(id, "_cv_repaired")
  m <- NULL
  for (k in seq_len(nrow(x))) { m <- meta_txt(x$collection[k], x$dir[k]); if (!is.null(m)) break }
  if (is.null(m)) { cand <- unique(x$dir_key); for (cl in c("component-models", "real-time-component-models",
                    "cv-ensemble-models", "real-time-ensemble-models")) for (dd in cand) if (is.null(m)) m <- meta_txt(cl, dd) }
  parts <- strsplit(id, "-", fixed = TRUE)[[1]]
  note <- ids[dir %in% x$dir_key, paste(unique(na.omit(note)), collapse = "; ")]
  members <- if (!is.null(m$team_members)) trimws(strsplit(gsub("'", "", m$team_members), ",")[[1]]) else character()
  out <- list(
    team_abbr = parts[1], model_abbr = parts[2],
    team_name = m$team_name %||% NA, model_name = m$model_name %||% NA,
    model_contributors = lapply(members, function(n) list(name = n)),
    forecast_mode = rec,
    paired_model_id = pair_of(id, rec),
    source_dirs = as.list(sort(unique(paste0(x$collection, "/", x$dir)))),
    seasons = as.list(sort(unique(fm[model_id == id, season]))),
    this_model_is_an_ensemble = isTRUE(as.logical(m$this_model_is_an_ensemble)),
    real_time_start_season = if (is.null(m$real_time_start_season)) NULL else as.character(m$real_time_start_season),
    methods = if (is.null(m$methods)) NULL else trimws(m$methods),
    data_inputs = paste(na.omit(unlist(m[c("data_source1", "data_source2")])), collapse = ", "),
    designated_model = FALSE,
    notes = paste(c(if (nzchar(note)) note,
                    if (is_rep) paste("REPAIRED copy of", sub("_repaired$", "", id), "(user decision 2026-11-23: keep original and revised).",
                                      "FSN's stacking code dropped other models' probability for the last week of the year (week 52; week 53 in 2014/15)",
                                      "because CU-BMA labels that bin's end differently. Only that bin is recomputed, from FSN's own components and weights;",
                                      "all other values are identical to the original (see validation/cv-repair.csv)."),
                    switch(rec,
                      "real-time" = "Real-time record: forecasts as submitted (last version committed by the due date + 3 days). Do not combine with _train/_cv IDs.",
                      "training" = "Training record: the series held in component-models/ (training pin 2019-10-25 unless noted). Includes copies of real-time files; do not combine with plain IDs.",
                      "cross-validated" = "Leave-one-season-out cross-validated ensemble built by FSN from the _train components. Do not combine with plain IDs.")),
                  collapse = " "))
  out <- Filter(function(v) !is.null(v) && !(length(v) == 1 && is.na(v)), out)
  write_yaml(out, file.path(REPO_ROOT, "model-metadata", paste0(id, ".yml")))
  data.table(model_id = id, has_source_metadata = !is.null(m))
}
`%||%` <- function(a, b) if (is.null(a)) b else a
mm <- rbindlist(lapply(sort(unique(fm$model_id)), write_meta))
cat("model metadata files:", nrow(mm), " without source metadata.txt:", mm[has_source_metadata == FALSE, .N], "\n")
print(mm[has_source_metadata == FALSE])
