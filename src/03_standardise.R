# Step 03: extract every selected source version, standardise it (no value changes), and profile it.
#
# Standardisation = lower-case trimmed headers, trimmed strings, canonical bin labels.
# The raw strings are kept alongside, so later steps can prove nothing else changed.
#
# Outputs:
#   .cache/work/std/<blob>.parquet          one standardised table per distinct source blob (not committed)
#   validation/profile-files.csv            per selected file: structure and quality profile
#   validation/post-pin-compare.csv         pinned vs post-pin (formatting-fix) versions, parsed-value comparison

source("src/00_config.R")
stopifnot_source()
suppressPackageStartupMessages({ library(arrow); library(parallel) })

fm <- fread(file.path(VALIDATION_DIR, "file-map.csv"))
STD_DIR <- file.path(WORK_DIR, "std"); dir.create(STD_DIR, showWarnings = FALSE)
EXPECTED_COLS <- c("location", "target", "type", "unit", "bin_start_incl", "bin_end_notincl", "value")
WEEK_TARGETS <- c("Season onset", "Season peak week")
ILI_TARGETS <- c("1 wk ahead", "2 wk ahead", "3 wk ahead", "4 wk ahead", "Season peak percentage")
NA_STRINGS <- c("NA", "NaN", "", "nan", "null", "NULL")

read_blob <- function(blob) {
  txt <- git_blob(blob)
  raw <- fread(text = txt, colClasses = "character", na.strings = NULL, strip.white = FALSE)
  list(raw = raw, header = paste(names(raw), collapse = ","))
}

standardise <- function(blob) {
  f <- file.path(STD_DIR, paste0(blob, ".parquet"))
  if (file.exists(f)) {                       # cached: profile from the stored table
    d <- as.data.table(read_parquet(f))
    if ("src_header" %in% names(d)) return(profile(d, blob, d$src_header[1]))
    unlink(f)                                 # stale cache from an older version of this script
  }
  r <- read_blob(blob); d <- copy(r$raw)
  setnames(d, tolower(trimws(gsub('"', "", names(d)))))
  stopifnot(setequal(names(d), EXPECTED_COLS))
  setcolorder(d, EXPECTED_COLS)
  setnames(d, c("bin_start_incl", "bin_end_notincl", "value"), c("bin_start_raw", "bin_end_raw", "value_raw"))
  for (col in c("location", "target", "type", "unit")) set(d, j = col, value = trimws(d[[col]]))
  d[, value := suppressWarnings(as.numeric(trimws(value_raw)))]
  d[, value_missing := trimws(value_raw) %in% NA_STRINGS]
  d[, value_unparsed := is.na(value) & !value_missing]
  # canonical bin label (Bin rows only)
  d[, bin_label := NA_character_]
  d[type == "Bin" & target %in% WEEK_TARGETS & trimws(bin_start_raw) == "none", bin_label := "none"]
  d[type == "Bin" & target %in% WEEK_TARGETS & trimws(bin_start_raw) != "none",
    bin_label := as.character(as.integer(round(as.numeric(trimws(bin_start_raw)))))]
  d[type == "Bin" & target %in% ILI_TARGETS, bin_label := sprintf("%.1f", round(as.numeric(trimws(bin_start_raw)), 1))]
  d[, label_off_grid := type == "Bin" & !is.na(bin_label) & bin_label != "none" &
      abs(as.numeric(trimws(bin_start_raw)) - as.numeric(bin_label)) > 1e-9]
  d[, row_id := .I]
  d[, src_header := r$header]
  write_parquet(d, f)
  profile(d, blob, r$header)
}

profile <- function(d, blob, header) {
  b <- d[type == "Bin"]
  sums <- b[, .(s = sum(value, na.rm = TRUE), n = .N, nna = sum(is.na(value))), by = .(location, target)]
  dev <- abs(sums$s - 1)
  data.table(
    blob = blob, header = header, n_rows = nrow(d),
    n_locations = uniqueN(d$location), locations_ok = setequal(unique(d$location), c("US National", paste("HHS Region", 1:10))),
    targets = paste(sort(unique(d$target)), collapse = "|"),
    types = paste(sort(unique(d$type)), collapse = "|"),
    dup_keys = d[, .N, by = .(location, target, type, bin_label)][N > 1 & !is.na(bin_label), .N],
    n_point = d[type == "Point", .N], point_missing = d[type == "Point" & value_missing, .N],
    bin_missing = b[value_missing == TRUE, .N], value_unparsed = d[value_unparsed == TRUE, .N],
    negative = b[value < 0, .N], label_off_grid = d[label_off_grid == TRUE, .N],
    label_style_int_dot0 = b[target %in% WEEK_TARGETS & grepl("\\.0$", bin_start_raw), .N] > 0,
    n_ili_bins = paste(sort(unique(sums[target %in% ILI_TARGETS, n])), collapse = "|"),
    n_week_bins = paste(sort(unique(sums[target %in% WEEK_TARGETS, n])), collapse = "|"),
    sum_dev_max = if (length(dev)) max(dev) else NA_real_,
    n_sum_dev_gt_1e8 = sum(dev > 1.5e-8), n_sum_dev_gt_1e3 = sum(dev > 1e-3), n_sum_dev_gt_0.1 = sum(dev > 0.1),
    n_forecasts = nrow(sums)
  )
}

sup <- fread(file.path(VALIDATION_DIR, "file-map-superseded.csv"))
blobs <- unique(c(fm$blob, sup$blob))           # superseded versions are kept in auxiliary-data (step 07)
done <- sub("\\.parquet$", "", list.files(STD_DIR))
message(length(blobs), " distinct blobs; ", length(intersect(blobs, done)), " already standardised")
t0 <- Sys.time()
prof <- rbindlist(mclapply(blobs, function(b) tryCatch(standardise(b), error = function(e)
  data.table(blob = b, error = conditionMessage(e))), mc.cores = max(1L, detectCores() - 2L)), fill = TRUE)
message("standardised in ", round(difftime(Sys.time(), t0, units = "mins"), 1), " min")
if ("error" %in% names(prof) && prof[!is.na(error), .N]) { print(prof[!is.na(error)]); stop("standardisation errors") }

pf <- merge(fm[, .(model_id, record, origin_date, season, blob, path)], prof, by = "blob")
setorder(pf, record, model_id, origin_date)
fwrite_csv(pf, "profile-files.csv")

# ---- post-pin formatting fixes: do parsed values change? ----------------------------------
rv <- fread(file.path(VALIDATION_DIR, "file-map-review.csv"))
pp <- rv[item %like% "edited after pin"]
pp[, c("pin_blob", "master_blob") := tstrsplit(detail, " -> ", fixed = TRUE)]
cmp_one <- function(a, b) {
  x <- standardise_tbl(a); y <- standardise_tbl(b)
  k <- c("location", "target", "type", "bin_label")
  m <- merge(x[, c(k, "value"), with = FALSE], y[, c(k, "value"), with = FALSE], by = k, all = TRUE)
  data.table(rows_pin = nrow(x), rows_master = nrow(y), unmatched = m[is.na(value.x) != is.na(value.y), .N],
             n_value_diff = m[!is.na(value.x) & !is.na(value.y) & value.x != value.y, .N],
             max_abs_diff = suppressWarnings(max(abs(m$value.x - m$value.y), na.rm = TRUE)))
}
standardise_tbl <- function(blob) {
  f <- file.path(STD_DIR, paste0(blob, ".parquet"))
  if (!file.exists(f) || !"src_header" %in% names(read_parquet(f, as_data_frame = FALSE))) {
    unlink(f); standardise(blob)
  }
  as.data.table(read_parquet(f))
}
pp_cmp <- rbindlist(mclapply(seq_len(nrow(pp)), function(i) cbind(pp[i, .(path, pin_blob, master_blob)],
                    cmp_one(pp$pin_blob[i], pp$master_blob[i])), mc.cores = max(1L, detectCores() - 2L)))
fwrite_csv(pp_cmp, "post-pin-compare.csv")

# ---- summary ---------------------------------------------------------------------------------
cat("\n=== conversion-set profile ===\n")
cat("files:", nrow(pf), " distinct blobs:", uniqueN(pf$blob), " rows (sum over files):", format(sum(pf$n_rows), big.mark = ","), "\n")
print(pf[, .(files = .N, rows = sum(n_rows)), by = record])
cat("\nheaders:\n"); print(pf[, .N, by = header])
cat("\nstructure problems (files):\n")
print(pf[, .(bad_locations = sum(!locations_ok), dup_keys = sum(dup_keys > 0), unparsed = sum(value_unparsed > 0),
             negative = sum(negative > 0), off_grid_labels = sum(label_off_grid > 0), bin_missing = sum(bin_missing > 0))])
cat("\nbin counts:\n"); print(pf[, .N, by = .(n_ili_bins, n_week_bins)])
cat("\nmissing Point values:", sum(pf$point_missing), "in", pf[point_missing > 0, .N], "files\n")
cat("\nprobability sums (forecasts = file x location x target):\n")
print(pf[, .(forecasts = sum(n_forecasts), dev_gt_1.5e8 = sum(n_sum_dev_gt_1e8), dev_gt_1e3 = sum(n_sum_dev_gt_1e3),
             dev_gt_0.1 = sum(n_sum_dev_gt_0.1), files_with_dev_gt_0.1 = sum(n_sum_dev_gt_0.1 > 0)), by = record])
cat("\npost-pin formatting fixes:\n")
print(pp_cmp[, .(files = .N, any_value_diff = sum(n_value_diff > 0 | unmatched > 0), max_abs_diff = max(max_abs_diff)),
             by = .(dir = basename(dirname(path)))])
