# Diagnostic: why do some cv-ensemble pmfs not sum to 1?
# Rebuilds cv-ensemble files from the pinned component files + weights, mimicking
# scripts/stack_forecasts.R (FluSight::read_entry label normalisation, left_join chain on the
# first component's rows, rowSums(na.rm = TRUE)), and compares with the files FSN committed.
#
# Usage: Rscript src/diag_cv_ensembles.R            (writes validation/diag-cv-ensembles.csv)

source("src/00_config.R")
PIN <- fread(file.path(VALIDATION_DIR, "source-pin.csv"))[name == "training_pin", commit]

show_csv <- function(path) {
  txt <- tryCatch(git("show", paste0(PIN, ":", path)), error = function(e) NULL)
  if (is.null(txt)) return(NULL)
  fread(text = txt, colClasses = "character")
}
read_entry <- function(path) {          # FluSight::read_entry equivalent
  d <- show_csv(path); if (is.null(d)) return(NULL)
  setnames(d, tolower(names(d)))
  fmt <- function(x) { i <- !is.na(x) & x != "none" & x != "NA"
    x[i] <- trimws(format(round(as.numeric(x[i]), 1), nsmall = 1)); x }
  d[, value := as.numeric(value)]
  d[, bin_start_incl := fmt(bin_start_incl)][, bin_end_notincl := fmt(bin_end_notincl)]
  d[]
}

ids <- show_csv("model-forecasts/component-models/model-id-map.csv")
setnames(ids, c("model_id", "model_dir", "complete"))
KEY <- c("location", "target", "type", "unit", "bin_start_incl", "bin_end_notincl")
if (nzchar(Sys.getenv("DIAG_START_ONLY"))) KEY <- setdiff(KEY, "bin_end_notincl")

rebuild <- function(ens, week) {
  w <- show_csv(sprintf("weights/%s.csv", ens))
  w[, weight := as.numeric(weight)]
  yr <- as.integer(sub(".*-", "", week)); ew <- as.integer(sub("EW([0-9]+)-.*", "\\1", week))
  ssn <- if (ew >= 40) sprintf("%d/%d", yr, yr + 1) else sprintf("%d/%d", yr - 1, yr)
  w <- w[season == ssn]
  entries <- lapply(seq_len(nrow(ids)), function(i) {
    e <- read_entry(sprintf("model-forecasts/component-models/%s/%s-%s.csv", ids$model_dir[i], week, ids$model_dir[i]))
    if (is.null(e)) return(NULL)
    e[, component_model_id := ids$model_id[i]]
    jw <- intersect(c("component_model_id", "target", "location"), names(w))
    e <- merge(e, w[, c(jw, "weight"), with = FALSE], by = jw, all.x = TRUE, sort = FALSE)
    e[, wv := weight * value]
    e[, c(KEY, "wv"), with = FALSE][, model := ids$model_id[i]]
  })
  names(entries) <- ids$model_id
  entries <- Filter(Negate(is.null), entries)
  # FSN: Reduce(left_join) -> only the FIRST component's rows are kept
  base <- entries[[1]][, KEY, with = FALSE]
  long <- rbindlist(entries)
  joined <- merge(base, long, by = KEY, all.x = TRUE)
  fsn_like <- joined[, .(value = sum(wv, na.rm = TRUE)), by = KEY]
  # which components' rows failed to match the first component's keys?
  miss <- rbindlist(lapply(entries, function(e) {
    m <- fsetdiff(e[type == "Bin", KEY, with = FALSE], base)
    data.table(model = e$model[1], unmatched_rows = nrow(m),
               eg = if (nrow(m)) paste(m$target[1], m$bin_start_incl[1], m$unit[1]) else "")
  }))
  committed <- read_entry(sprintf("model-forecasts/cv-ensemble-models/%s/%s-%s.csv", ens, week, ens))
  cmp <- merge(fsn_like, committed[, c(KEY, "value"), with = FALSE], by = KEY, suffixes = c("_rebuilt", "_committed"))
  cmp <- cmp[type == "Bin"]
  sums <- cmp[, .(rebuilt = sum(value_rebuilt), committed = sum(value_committed)), by = .(location, target)]
  list(summary = data.table(ensemble = ens, week = week, n_components = length(entries),
                            first_component = names(entries)[1],
                            max_abs_diff_vs_committed = max(abs(cmp$value_rebuilt - cmp$value_committed)),
                            committed_min_sum = min(sums$committed), rebuilt_min_sum = min(sums$rebuilt)),
       miss = miss[unmatched_rows > 0][, `:=`(ensemble = ens, week = week)])
}

cases <- CJ(ens = c("equal-weights", "target-type-based-weights"),
            week = c("EW45-2010", "EW02-2013", "EW45-2015", "EW03-2017", "EW48-2018"))
res <- lapply(seq_len(nrow(cases)), function(i) rebuild(cases$ens[i], cases$week[i]))
summ <- rbindlist(lapply(res, `[[`, "summary")); miss <- rbindlist(lapply(res, `[[`, "miss"))
options(width = 200); print(summ); print(unique(miss[, .(model, unmatched_rows, eg)])[order(-unmatched_rows)])
fwrite_csv(summ, "diag-cv-ensembles.csv")
