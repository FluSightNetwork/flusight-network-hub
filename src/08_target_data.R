# Step 08: target data.
#
# 2010/11-2018/19: scores/target-multivals.csv in the source repo (FSN's truths, one-decimal wILI scale),
#   with tied peak weeks resolved by src/peak_week_ties.csv (unrounded ILINet maximum).
# 2019/20: FSN computed no truths. Derived here with src/compute_truths.R (FSN's definitions, ILINet as of
#   issue 202028, CDC 2019/20 baselines) - user decision 2026-11-23. The method reproduces all FSN
#   truths for 2010/11-2018/19 exactly (validation/truth-recompute-*.csv). The same method fills weekly
#   observations FSN did not compute (late-2018/19 weeks). 2019/20 onset/peak use a season ending EW09-2020.
#
# Outputs (committed):
#   target-data/time-series.csv        target_end_date, location, observation (weekly wILI, one decimal)
#   target-data/oracle-output.parquet  oracle rows keyed like model output:
#       ili perc          origin_date, location, target, horizon, target_end_date: pmf (1 at observed bin) + median
#       seasonal targets  origin_date, location, target (horizon/target_end_date NA): pmf
#     Seasonal truths repeat for every origin_date in the season (user decision 2026-11-22).

source("src/compute_truths.R")
suppressPackageStartupMessages(library(arrow))
DERIVED_SEASONS <- 2019L
TD <- file.path(REPO_ROOT, "target-data"); dir.create(TD, showWarnings = FALSE)
ILI_BINS <- sprintf("%.1f", seq(0, 13, by = 0.1))

tm <- fread(text = git("show", paste0(SOURCE_MASTER_SHA, ":scores/target-multivals.csv")), colClasses = "character")
setnames(tm, c("year", "cal_week", "season", "model_week", "location", "target", "valid"))
tm[, origin_date := mmwr_week_end(as.integer(year), as.integer(cal_week))]

# ---- weekly wILI: "h wk ahead" truth at origin o is the observation for week o + 7h ----------------
wk <- tm[grepl("wk ahead", target)]
wk[, h := as.integer(substr(target, 1, 1))]
wk[, target_end_date := origin_date + 7L * h]
obs <- unique(wk[, .(target_end_date, location, observation = as.numeric(valid))])
obs[, truth_source := "FSN scores/target-multivals.csv"]
# derived weekly observations: all of 2019/20, plus any weeks FSN's truths do not cover in earlier
# seasons (e.g. 11 late-2018/19 target weeks); same method, which reproduces FSN's values exactly
obs_d <- rbindlist(lapply(2010:max(DERIVED_SEASONS), function(y) rbindlist(lapply(LOCATIONS, function(l) weekly_truths(y, l)))))
obs_d <- obs_d[!obs[, .(target_end_date, location)], on = .(target_end_date, location)]
# for FSN seasons, keep only derived weeks that some hub forecast targets
needed_ted <- open_dataset(file.path(REPO_ROOT, "model-output"), format = "parquet",
                           schema = arrow::schema(origin_date = date32(), location = utf8(), target = utf8(), horizon = int32(),
                                                  target_end_date = date32(), output_type = utf8(), output_type_id = utf8(), value = float64())) |>
  dplyr::filter(target == "ili perc") |> dplyr::distinct(target_end_date) |> dplyr::collect()
obs_d <- obs_d[season_of(target_end_date) %in% sprintf("%d/%d", DERIVED_SEASONS, DERIVED_SEASONS + 1L) |
               target_end_date %in% needed_ted$target_end_date]
obs <- rbind(obs, obs_d[, .(target_end_date, location, observation,
                            truth_source = paste0("derived: ILINet issue ", issue_used, " (src/compute_truths.R)"))])
conf <- obs[, .(n = uniqueN(observation)), by = .(target_end_date, location)][n > 1]
if (nrow(conf)) { print(conf); stop("conflicting weekly observations in target-multivals") }
setorder(obs, location, target_end_date)
fwrite(obs, file.path(TD, "time-series.csv"))
message("time-series: ", nrow(obs), " rows, ", min(obs$target_end_date), " to ", max(obs$target_end_date))

# ---- hub task combinations to cover -----------------------------------------------------------
sch <- arrow::schema(origin_date = date32(), location = utf8(), target = utf8(), horizon = int32(),
                     target_end_date = date32(), output_type = utf8(), output_type_id = utf8(), value = float64())
ds <- open_dataset(file.path(REPO_ROOT, "model-output"), format = "parquet", schema = sch)
tasks <- ds |> dplyr::distinct(origin_date, location, target, horizon, target_end_date) |> dplyr::collect() |> as.data.table()
tasks[, season := season_of(origin_date)]
wk_ids <- ds |> dplyr::filter(target %in% c("season onset wk", "season peak wk")) |>
  dplyr::distinct(origin_date, target, output_type_id) |> dplyr::collect() |> as.data.table()
wk_ids[, season := season_of(origin_date)]
wk_ids <- unique(wk_ids[, .(season, target, output_type_id)])

# ---- ili perc oracle ------------------------------------------------------------------------------
ili <- merge(tasks[target == "ili perc"], obs, by = c("target_end_date", "location"))
ili[, bin := sprintf("%.1f", pmin(floor(observation * 10 + 1e-9) / 10, 13))]
ili_pmf <- ili[, .(output_type_id = ILI_BINS), by = .(origin_date, location, target, horizon, target_end_date, bin)]
ili_pmf[, `:=`(output_type = "pmf", oracle_value = as.numeric(output_type_id == bin))]
ili_med <- ili[, .(origin_date, location, target, horizon, target_end_date, output_type = "median",
                   output_type_id = NA_character_, oracle_value = observation)]

# ---- seasonal truths ----------------------------------------------------------------------------
tmap <- c("Season onset" = "season onset wk", "Season peak week" = "season peak wk", "Season peak percentage" = "season peak perc")
st <- unique(tm[target %in% names(tmap), .(season, location, target = tmap[target], valid)])
st_d <- rbindlist(lapply(DERIVED_SEASONS, function(y) rbindlist(lapply(LOCATIONS, function(l) seasonal_truths(y, l)))))
stopifnot(st_d[target == "Season peak week", .N, by = .(season, location)][, all(N == 1)])  # no ties in derived seasons
st <- rbind(st, st_d[, .(season, location, target = tmap[target], valid)])
ties <- fread(file.path(SRC_DIR, "peak_week_ties.csv"))
chosen <- ties[chosen == TRUE, .(season, location, target = "season peak wk", valid = as.character(week))]
multi <- st[, .N, by = .(season, location, target)][N > 1]
stopifnot(all(multi$target == "season peak wk"))
stopifnot(nrow(merge(multi, chosen, by = c("season", "location", "target"))) == nrow(multi))
st <- rbind(st[!multi, on = .(season, location, target)], chosen)
stopifnot(!anyDuplicated(st[, .(season, location, target)]))
# labels -> hub output_type_id
st[, y0 := as.integer(substr(season, 1, 4))]
st[target != "season peak perc" & valid != "none",
   obs_id := format(mmwr_week_end(ifelse(as.integer(valid) >= 30L, y0, y0 + 1L), as.integer(valid)))]
st[target != "season peak perc" & valid == "none", obs_id := "none"]
st[target == "season peak perc", obs_id := sprintf("%.1f", pmin(floor(as.numeric(valid) * 10 + 1e-9) / 10, 13))]
st[, season := sub("/", "/", season)]

sea_tasks <- tasks[target != "ili perc"]
sea <- merge(sea_tasks, st[, .(season, location, target, obs_id)], by = c("season", "location", "target"))
ids_for <- function(s, tg) if (tg == "season peak perc") ILI_BINS else wk_ids[season == s & target == tg, output_type_id]
sea_pmf <- sea[, .(output_type_id = ids_for(season, target)), by = .(season, origin_date, location, target, horizon, target_end_date, obs_id)]
missing_obs <- sea[!obs_id %in% c(ids_for(season[1], target[1])), .N]
sea_pmf[, `:=`(output_type = "pmf", oracle_value = as.numeric(output_type_id == obs_id))]
bad <- sea_pmf[, .(s = sum(oracle_value)), by = .(origin_date, location, target)][s != 1]
if (nrow(bad)) { print(head(bad)); stop("seasonal oracle: observed value not among the hub's bins") }

cols <- c("origin_date", "location", "target", "horizon", "target_end_date", "output_type", "output_type_id", "oracle_value")
oracle <- rbind(ili_pmf[, ..cols], ili_med[, ..cols], sea_pmf[, ..cols])
oracle[, horizon := as.integer(horizon)]
setorder(oracle, origin_date, location, target, horizon, output_type, output_type_id)
write_parquet(oracle, file.path(TD, "oracle-output.parquet"))

cat("\n=== target data ===\n")
print(oracle[, .(rows = .N, origins = uniqueN(origin_date), seasons = paste(range(season_of(origin_date)), collapse = "–")),
             by = .(target, output_type)])
cov <- merge(tasks[, .N, by = .(season = season_of(origin_date), target)],
             unique(oracle[, .(origin_date, location, target, horizon)])[, .(with_truth = .N), by = .(season = season_of(origin_date), target)],
             by = c("season", "target"), all.x = TRUE)
cat("\nhub tasks with truth, by season:\n"); print(dcast(cov, season ~ target, value.var = "with_truth", fill = 0))
cat("hub tasks without truth:", sum(cov$N) - sum(cov$with_truth, na.rm = TRUE), "of", sum(cov$N), "\n")
