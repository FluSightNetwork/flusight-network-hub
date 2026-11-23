# Step 10c: validate target data.
#   - hubValidations::validate_target_submission() on time-series.csv and oracle-output.parquet.
#   - Its `target_tbl_output_type_ids` check is NOT round-aware: for a hub whose pmf output_type_ids
#     differ by round (each season has its own week-date bins), it expects the union of every round's
#     ids for every task, even with `round_id` set (hubValidations 3.0.0; to be reported). That check is
#     replaced by a round-aware one below: for every oracle pmf task, the output_type_ids must equal the
#     required ids of that season's round/target in tasks.json, and exactly one must have oracle_value 1.
# Output: validation/target-data-validation.csv

source("src/00_config.R")
suppressPackageStartupMessages({ library(hubValidations); library(arrow); library(jsonlite) })

classify <- function(x) {
  cl <- class(x)
  if (any(cl == "check_success")) "pass" else if (any(cl == "check_info")) "info"
  else if (any(grepl("failure|error", cl))) "FAIL" else paste(cl, collapse = "/")
}
run <- function(f, tt) {
  v <- validate_target_submission(hub_path = REPO_ROOT, file_path = f, target_type = tt)
  rbind(data.table(file = "hub-config", check = names(v[["hub-config"]]), result = vapply(v[["hub-config"]], classify, "")),
        data.table(file = f, check = names(v[[f]]), result = vapply(v[[f]], classify, "")))
}
res <- rbind(run("time-series.csv", "time-series"), run("oracle-output.parquet", "oracle-output"))
res[file == "oracle-output.parquet" & check == "target_tbl_output_type_ids",
    result := paste0("replaced (not round-aware): was ", result)]

# ---- round-aware completeness check ----------------------------------------------------------------
tasks <- fromJSON(file.path(REPO_ROOT, "hub-config", "tasks.json"), simplifyVector = FALSE)
req <- rbindlist(lapply(tasks$rounds, function(r) rbindlist(lapply(r$model_tasks, function(mt) {
  if (is.null(mt$output_type$pmf)) return(NULL)
  data.table(season = r$round_name, target = unlist(mt$task_ids$target$optional),
             ids = list(sort(unlist(mt$output_type$pmf$output_type_id$required))))
}))))
o <- as.data.table(read_parquet(file.path(REPO_ROOT, "target-data", "oracle-output.parquet")))[output_type == "pmf"]
o[, season := season_of(origin_date)]
per_task <- o[, .(ids = list(sort(output_type_id)), n_one = sum(oracle_value == 1), n_other = sum(!oracle_value %in% c(0, 1))),
              by = .(season, origin_date, location, target, horizon)]
per_task <- merge(per_task, req, by = c("season", "target"), suffixes = c("", "_required"), all.x = TRUE)
per_task[, ids_match := mapply(identical, ids, ids_required)]
bad <- per_task[!ids_match | n_one != 1 | n_other > 0]
res <- rbind(res, data.table(file = "oracle-output.parquet", check = "round_aware_output_type_ids_and_single_observed",
                             result = if (nrow(bad)) "FAIL" else "pass"))
cat("oracle pmf tasks:", nrow(per_task), " with exact required ids and one observed bin:", nrow(per_task) - nrow(bad), "\n")

fwrite_csv(res, "target-data-validation.csv")
print(res)
if (res[result == "FAIL", .N]) { if (nrow(bad)) print(head(bad)); quit(status = 1) }
cat("TARGET DATA VALID\n")
