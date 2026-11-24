# Steps 04-06: convert every file-map entry into a hubverse model-output parquet file.
#
# Per source file (already standardised by step 03):
#   04 quality   per forecast (location x target): pmf sum within 1.5e-8 of 1 -> keep as is;
#                off by <= 0.1 -> divide by the sum (logged); off by > 0.1, any missing or negative
#                bin value -> forecast excluded (rows written to excluded_output/, logged)
#   05 medians   weekly `ili perc` only: left edge of the first bin whose cumulative probability
#                (after renormalisation) reaches 0.5; the open 13-100 bin gives 13.0 (flagged)
#   06 write     model-output/<model_id>/<origin_date>-<model_id>.parquet
#
# Source Point rows are not converted; they are kept unchanged for auxiliary-data/ (step 07).
#
# Outputs:
#   model-output/**                                  (committed)
#   .cache/work/convert/{changes,excluded,points,stats}/<model_id>__<origin>.parquet  (combined in step 07)

source("src/00_config.R")
suppressPackageStartupMessages({ library(arrow); library(parallel) })

fm <- load_file_map()
if (nzchar(Sys.getenv("FSN_ONLY_MODELS"))) fm <- fm[model_id %in% strsplit(Sys.getenv("FSN_ONLY_MODELS"), ",")[[1]]]
STD_DIR <- file.path(WORK_DIR, "std")
OUT_DIR <- file.path(REPO_ROOT, "model-output")
CV_DIR <- file.path(WORK_DIR, "convert")
for (d in c("changes", "excluded", "points", "stats")) dir.create(file.path(CV_DIR, d), recursive = TRUE, showWarnings = FALSE)

SUM_TOL <- 1.5e-8      # hubValidations sum-to-1 tolerance (sqrt(.Machine$double.eps))
RENORM_MAX <- 0.1      # CDC 2015/16 rule

TARGET_MAP <- data.table(
  target = c("1 wk ahead", "2 wk ahead", "3 wk ahead", "4 wk ahead",
             "Season peak percentage", "Season onset", "Season peak week"),
  hub_target = c(rep("ili perc", 4), "season peak perc", "season onset wk", "season peak wk"),
  horizon = c(1:4, rep(NA_integer_, 3)),
  week_target = c(rep(FALSE, 5), TRUE, TRUE))

week_label_to_date <- function(label, origin) {
  out <- rep(NA_character_, length(label))
  is_wk <- label != "none"
  wk <- as.integer(label[is_wk])
  y0 <- as.integer(substr(season_of(origin), 1, 4))
  yr <- ifelse(wk >= 30L, y0, y0 + 1L)
  out[is_wk] <- format(mmwr_week_end(yr, wk))
  out[!is_wk] <- "none"
  out
}

convert_one <- function(i) {
  r <- fm[i]
  key <- paste0(r$model_id, "__", r$origin_date)
  d <- as.data.table(read_parquet(file.path(STD_DIR, paste0(r$blob, ".parquet"))))
  origin <- as.Date(r$origin_date)

  # ---- points: kept unchanged for auxiliary-data -------------------------------------
  pts <- d[type == "Point", .(model_id = r$model_id, origin_date = origin, location, target, unit,
                             value_raw, value, source_row = row_id)]
  write_parquet(pts, file.path(CV_DIR, "points", paste0(key, ".parquet")))

  # ---- pmf rows ---------------------------------------------------------------------
  b <- merge(d[type == "Bin"], TARGET_MAP, by = "target", sort = FALSE)
  stopifnot(nrow(b) == d[type == "Bin", .N])
  b[, output_type_id := fifelse(week_target, week_label_to_date(bin_label, origin), bin_label)]

  # ---- 04 quality -------------------------------------------------------------------
  f <- b[, .(n_bins = .N, sum = sum(value), any_missing = any(is.na(value)), any_negative = any(value < 0, na.rm = TRUE)),
         by = .(location, target)]
  f[, dev := abs(sum - 1)]
  f[, action := fcase(any_missing | is.na(sum), "excluded: missing bin value",
                      any_negative, "excluded: negative bin value",
                      dev > RENORM_MAX, "excluded: sum off by more than 0.1",
                      dev > SUM_TOL, "renormalised",
                      default = "unchanged")]
  b <- merge(b, f[, .(location, target, action, sum)], by = c("location", "target"), sort = FALSE)
  excl <- b[startsWith(action, "excluded")]
  if (nrow(excl)) write_parquet(excl[, .(model_id = r$model_id, origin_date = origin, location, target, type, unit,
                                         bin_start_raw, bin_end_raw, value_raw, value, source_row = row_id, action)],
                                file.path(CV_DIR, "excluded", paste0(key, ".parquet")))
  b <- b[!startsWith(action, "excluded")]
  b[action == "renormalised", value := value / sum]
  chg <- f[action != "unchanged", .(model_id = r$model_id, origin_date = origin, location, target, action,
                                    original_sum = sum, n_bins)]
  if (nrow(chg)) write_parquet(chg, file.path(CV_DIR, "changes", paste0(key, ".parquet")))

  pmf <- b[, .(origin_date = origin, location, target = hub_target, horizon,
               output_type = "pmf", output_type_id, value, label_num = suppressWarnings(as.numeric(bin_label)), week_target)]

  # ---- 05 medians (weekly ili perc only) ------------------------------------------------
  ili <- pmf[target == "ili perc"]
  setorder(ili, location, horizon, label_num)
  med <- ili[, { cp <- cumsum(value); j <- which(cp >= 0.5 - 1e-12)[1]
                 .(value = label_num[j], open_bin = label_num[j] >= 13) }, by = .(location, horizon)]
  med[, `:=`(origin_date = origin, target = "ili perc", output_type = "median", output_type_id = NA_character_)]

  # ---- 06 assemble & write ------------------------------------------------------------------
  out <- rbind(pmf[, .(origin_date, location, target, horizon, output_type, output_type_id, value)],
               med[, .(origin_date, location, target, horizon, output_type, output_type_id, value)])
  out[, target_end_date := fifelse(is.na(horizon), as.Date(NA), origin_date + 7L * horizon)]
  setcolorder(out, c("origin_date", "location", "target", "horizon", "target_end_date", "output_type", "output_type_id", "value"))
  # deterministic row order
  out[, ord_type := match(output_type, c("pmf", "median"))]
  out[, ord_id := suppressWarnings(as.numeric(output_type_id))]
  setorder(out, location, target, horizon, ord_type, ord_id, output_type_id)
  out[, c("ord_type", "ord_id") := NULL]
  out[, horizon := as.integer(horizon)]

  dest <- file.path(OUT_DIR, r$model_id); dir.create(dest, showWarnings = FALSE, recursive = TRUE)
  write_parquet(as.data.frame(out), file.path(dest, sprintf("%s-%s.parquet", r$origin_date, r$model_id)))

  st <- data.table(model_id = r$model_id, origin_date = origin, record = r$record, blob = r$blob,
                   source_bin_rows = nrow(d[type == "Bin"]), source_point_rows = nrow(pts),
                   pmf_rows = nrow(pmf), median_rows = nrow(med), excluded_rows = nrow(excl),
                   forecasts = nrow(f), forecasts_renormalised = f[action == "renormalised", .N],
                   forecasts_excluded = f[startsWith(action, "excluded"), .N],
                   medians_open_bin = med[open_bin == TRUE, .N])
  write_parquet(st, file.path(CV_DIR, "stats", paste0(key, ".parquet")))
  st
}

t0 <- Sys.time()
res <- mclapply(seq_len(nrow(fm)), function(i) tryCatch(convert_one(i), error = function(e)
  data.table(model_id = fm$model_id[i], origin_date = as.Date(fm$origin_date[i]), error = conditionMessage(e))),
  mc.cores = max(1L, detectCores() - 2L))
res <- rbindlist(res, fill = TRUE)
message("converted ", nrow(res), " files in ", round(difftime(Sys.time(), t0, units = "mins"), 1), " min")
if ("error" %in% names(res) && res[!is.na(error), .N]) { print(res[!is.na(error)]); stop("conversion errors") }

print(res[, .(files = .N, pmf_rows = sum(pmf_rows), median_rows = sum(median_rows), excluded_rows = sum(excluded_rows),
              forecasts = sum(forecasts), renormalised = sum(forecasts_renormalised), excluded = sum(forecasts_excluded),
              medians_13plus = sum(medians_open_bin)), by = record])
