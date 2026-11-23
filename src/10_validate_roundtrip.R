# Step 10a: round-trip test. Proves the hub's pmf values are the source values, file by file.
#
# Independent of steps 03-04: re-reads every source file straight from git and maps it with
# its own (simpler) label logic. For each selected source file:
#   - every source Bin row maps to exactly one hub pmf row, or to the excluded log;
#   - hub rows with no source row are errors;
#   - unchanged forecasts: hub value == source value (exact, bit-identical double);
#   - renormalised forecasts: |hub - source / logged_sum| <= 1e-12;
#   - medians: equal the left edge of the first bin with cumulative probability >= 0.5.
# Also: for every training/cv file marked duplicate_of a real-time file, the two parquet files are
# byte-identical (md5).
#
# Output: validation/roundtrip.csv (one row per file) and a printed summary. Exit status 1 on failure.

source("src/00_config.R")
suppressPackageStartupMessages({ library(arrow); library(parallel); library(tools) })

fm <- load_file_map()
changes <- as.data.table(read_parquet(file.path(VALIDATION_DIR, "changes.parquet")))
excluded <- as.data.table(read_parquet(file.path(REPO_ROOT, "excluded_output", "excluded-forecasts.parquet")))
changes[, origin_date := as.Date(origin_date)]; excluded[, origin_date := as.Date(origin_date)]
setkey(changes, model_id, origin_date); setkey(excluded, model_id, origin_date)
repair_values <- as.data.table(read_parquet(file.path(VALIDATION_DIR, "cv-repair-values.parquet")))
repair_values[, origin_date := as.Date(origin_date)]; setkey(repair_values, model_id, origin_date)

tmap <- c("1 wk ahead" = "ili perc", "2 wk ahead" = "ili perc", "3 wk ahead" = "ili perc", "4 wk ahead" = "ili perc",
          "Season peak percentage" = "season peak perc", "Season onset" = "season onset wk", "Season peak week" = "season peak wk")

check_one <- function(i) {
  r <- fm[i]; origin <- as.Date(r$origin_date)
  # repaired cv files: start from FSN's original blob, then apply the logged week-52/53 repairs
  src <- fread(text = git("cat-file", "-p", sub("^repaired-", "", r$blob)), colClasses = "character", na.strings = NULL)
  setnames(src, tolower(trimws(names(src))))
  src <- src[trimws(type) == "Bin"]
  src[, `:=`(location = trimws(location), target = trimws(target), v = as.numeric(trimws(value)))]
  src[, hub_target := tmap[target]]
  src[, horizon := suppressWarnings(as.integer(substr(target, 1, 1)))]
  src[!grepl("wk ahead", target), horizon := NA_integer_]
  b <- trimws(src$bin_start_incl)
  wk <- src$target %in% c("Season onset", "Season peak week")
  id <- character(nrow(src))
  id[!wk] <- formatC(round(as.numeric(b[!wk]), 1), format = "f", digits = 1)
  y0 <- as.integer(substr(season_of(origin), 1, 4))
  wnum <- rep(NA_integer_, length(b))                          # full length, NA outside week bins
  wnum[wk & b != "none"] <- as.integer(round(as.numeric(b[wk & b != "none"])))
  id[wk & b == "none"] <- "none"
  j <- wk & b != "none"
  id[j] <- format(mmwr_week_end(ifelse(wnum[j] >= 30L, y0, y0 + 1L), wnum[j]))
  src[, output_type_id := id]
  if (isTRUE(r$repaired)) {
    rv <- repair_values[.(sub("_repaired$", "", r$model_id), origin)]
    src[, wk_label := fifelse(wk & b != "none", as.character(wnum), NA_character_)]
    src[rv, on = .(location, target, wk_label = bin_label), v := i.repaired]
    stopifnot(src[!is.na(wk_label) & wk_label %in% rv$bin_label, .N] == nrow(rv))
  }

  hub <- as.data.table(read_parquet(r$output_file))
  hp <- hub[output_type == "pmf"]
  ch <- changes[.(r$model_id, origin)][!is.na(location)]
  ex <- excluded[.(r$model_id, origin)][!is.na(location)]
  ex_fc <- unique(ex[, .(location, target)])

  src_ex <- src[ex_fc, on = .(location, target), nomatch = 0L]
  src_in <- src[!ex_fc, on = .(location, target)]
  m <- merge(src_in, hp[, .(location, hub_target = target, horizon, output_type_id, hub_value = value)],
             by = c("location", "hub_target", "horizon", "output_type_id"), all = TRUE)
  m <- merge(m, ch[action == "renormalised", .(location, target, original_sum)], by = c("location", "target"), all.x = TRUE)
  unchanged <- m[!is.na(v) & !is.na(hub_value) & is.na(original_sum)]
  renorm <- m[!is.na(v) & !is.na(hub_value) & !is.na(original_sum)]

  # medians
  med <- hub[output_type == "median"]
  ili <- hp[target == "ili perc"][, num := as.numeric(output_type_id)]
  setorder(ili, location, horizon, num)
  exp_med <- ili[, .(expected = num[which(cumsum(value) >= 0.5 - 1e-12)[1]]), by = .(location, horizon)]
  mm <- merge(med[, .(location, horizon, value)], exp_med, by = c("location", "horizon"), all = TRUE)

  data.table(model_id = r$model_id, origin_date = origin, record = r$record,
             src_bin_rows = nrow(src), src_rows_excluded = nrow(src_ex), excluded_logged = nrow(ex),
             hub_pmf_rows = nrow(hp),
             src_rows_unmatched = m[is.na(hub_value), .N], hub_rows_without_source = m[is.na(v), .N],
             duplicate_keys = anyDuplicated(hp[, .(location, target, horizon, output_type_id)]) > 0,
             unchanged_rows = nrow(unchanged), unchanged_not_identical = unchanged[hub_value != v, .N],
             renorm_rows = nrow(renorm), renorm_max_err = if (nrow(renorm)) max(abs(renorm$hub_value - renorm$v / renorm$original_sum)) else 0,
             median_mismatch = mm[is.na(value) | is.na(expected) | value != expected, .N],
             ok = TRUE)
}

t0 <- Sys.time()
res <- rbindlist(mclapply(seq_len(nrow(fm)), function(i) tryCatch(check_one(i), error = function(e)
  data.table(model_id = fm$model_id[i], origin_date = as.Date(fm$origin_date[i]), error = conditionMessage(e), ok = FALSE)),
  mc.cores = max(1L, detectCores() - 2L)), fill = TRUE)
message("checked ", nrow(res), " files in ", round(difftime(Sys.time(), t0, units = "mins"), 1), " min")
res[is.na(ok) | ok == TRUE, ok := src_rows_unmatched == 0 & hub_rows_without_source == 0 & !duplicate_keys &
      unchanged_not_identical == 0 & renorm_max_err <= 1e-12 & median_mismatch == 0 &
      src_rows_excluded == excluded_logged]

# ---- duplicates are byte-identical -------------------------------------------------------------
dups <- fm[!is.na(duplicate_of) & duplicate_of != ""]
dups[, c("dup_model", "dup_origin") := tstrsplit(duplicate_of, " ", fixed = TRUE)]
dups[, dup_file := sprintf("model-output/%s/%s-%s.parquet", dup_model, dup_origin, dup_model)]
dups[, identical_bytes := md5sum(output_file) == md5sum(dup_file)]

fwrite_csv(res, "roundtrip.csv")
fwrite_csv(dups[, .(model_id, origin_date, output_file, duplicate_of, dup_file, identical_bytes)], "duplicate-check.csv")

cat("\n=== round-trip ===\n")
print(res[, .(files = .N, failed = sum(!ok), src_bin_rows = sum(src_bin_rows, na.rm = TRUE),
              unchanged_rows = sum(unchanged_rows, na.rm = TRUE), unchanged_not_identical = sum(unchanged_not_identical, na.rm = TRUE),
              renorm_rows = sum(renorm_rows, na.rm = TRUE), renorm_max_err = max(renorm_max_err, na.rm = TRUE),
              excluded_rows = sum(src_rows_excluded, na.rm = TRUE), median_mismatch = sum(median_mismatch, na.rm = TRUE)), by = record])
cat("duplicate pairs:", nrow(dups), " byte-identical:", sum(dups$identical_bytes), "\n")
if (res[ok == FALSE, .N] > 0) { print(head(res[ok == FALSE], 20)); quit(status = 1) }
if (!all(dups$identical_bytes)) { print(head(dups[identical_bytes == FALSE], 20)); quit(status = 1) }
cat("ALL CHECKS PASSED\n")
