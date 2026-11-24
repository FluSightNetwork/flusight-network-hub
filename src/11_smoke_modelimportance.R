# Step 11: downstream smoke test - modelimportance on hub data (pmf -> log score, median -> abs. error).
# Uses a project-local library (.cache/Rlib) for modelimportance and its deps.
#   1. 2018/19 components (real-time forecasts), weekly ili perc, pmf and median
#   2. components' training backcasts, 2015/16, season peak week (pmf). Seasonal targets have
#      empty horizon/target_end_date; those all-NA columns are dropped before scoring (known
#      hubEvals/scoringutils limitation, to be filed as an issue once the hub is live).
#   Workaround: modelimportance renames origin_date -> reference_date in forecasts only, so the oracle
#   column is renamed here too (worth reporting to modelimportance).

.libPaths(c(file.path(getwd(), ".cache", "Rlib"), .libPaths()))
source("src/00_config.R")
suppressPackageStartupMessages({ library(hubData); library(dplyr); library(arrow); library(modelimportance) })

hub <- connect_hub(REPO_ROOT, file_format = "parquet", skip_checks = TRUE)
oracle <- as.data.table(read_parquet(file.path(REPO_ROOT, "target-data", "oracle-output.parquet")))
drop_na_cols <- function(x) x[, names(x)[vapply(x, function(v) !all(is.na(v)), logical(1)) | names(x) == "output_type_id"], with = FALSE]

run <- function(label, models, origins, tgt, otype, hz = NULL) {
  fc <- hub |> filter(model_id %in% models, origin_date %in% origins, target == tgt, output_type == otype,
                      location %in% c("US National", "HHS Region 4")) |> collect() |> as.data.table()
  if (!is.null(hz)) fc <- fc[horizon == hz]
  orc <- oracle[target == tgt & output_type == otype & origin_date %in% origins & location %in% c("US National", "HHS Region 4")]
  if (!is.null(hz)) orc <- orc[horizon == hz]
  fc <- drop_na_cols(fc); orc <- drop_na_cols(orc)
  orc <- orc[, intersect(names(orc), c(names(fc), "oracle_value")), with = FALSE]
  # modelimportance renames the forecasts' origin_date to reference_date but not the oracle's
  setnames(orc, "origin_date", "reference_date", skip_absent = TRUE)
  t0 <- Sys.time()
  imp <- suppressMessages(model_importance(forecast_data = as.data.frame(fc), oracle_output_data = as.data.frame(orc),
                                           ensemble_fun = "simple_ensemble", importance_algorithm = "lomo"))
  imp <- as.data.table(imp)
  cat(sprintf("\n[%s] models=%d tasks=%d rows=%d  %.1fs\n", label, uniqueN(fc$model_id),
              nrow(unique(fc[, !c("model_id", "output_type_id", "value")])), nrow(imp), as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  print(imp[, .(mean_importance = mean(importance, na.rm = TRUE), n = .N, n_na = sum(is.na(importance))), by = model_id][order(-mean_importance)][1:5])
  imp[, test := label]
  imp
}

rt_models <- c("CU-BMA1", "Delphi-BasisRegression", "LANL-DBMplus", "Protea-Cheetah1", "ReichLab-KDE", "ReichLab-SARIMA2")
o1819 <- as.Date(c("2018-11-17", "2018-12-15", "2019-01-19"))
r1 <- run("real-time 2018/19, ili perc h=2, pmf", rt_models, o1819, "ili perc", "pmf", hz = 2L)
r2 <- run("real-time 2018/19, ili perc h=2, median", rt_models, o1819, "ili perc", "median", hz = 2L)
tr_models <- c("CU-BMA2", "Delphi-BasisRegression", "LANL-DBMplus", "Protea-Cheetah2", "ReichLab-KDE", "ReichLab-SARIMA2")
o1516 <- as.Date(c("2015-11-14", "2016-01-16", "2016-02-20"))
r3 <- run("backcasts 2015/16, season peak wk, pmf", tr_models, o1516, "season peak wk", "pmf")

res <- rbind(r1, r2, r3, fill = TRUE)
fwrite_csv(res, "smoke-modelimportance.csv")
ok <- res[, .(n = .N, na = sum(is.na(importance))), by = test]
print(ok)
if (any(ok$n == 0) || any(ok$na == ok$n)) quit(status = 1)
cat("SMOKE TEST PASSED\n")
