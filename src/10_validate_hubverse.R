# Step 10b: hubverse validation.
#   - hubAdmin::validate_hub_config()
#   - hubValidations::validate_submission() on every model-output file (submission window check skipped:
#     this is an archive). Set FSN_VALIDATE_SAMPLE=<n> to validate a stratified sample instead.
#   - hubData::connect_hub() + collect: row counts per model match the conversion stats.
#
# Output: validation/hubverse-validation.csv (one row per file: pass/fail and failing checks)

source("src/00_config.R")
suppressPackageStartupMessages({ library(hubValidations); library(hubAdmin); library(hubData); library(dplyr); library(parallel) })

cfg <- validate_hub_config(hub_path = REPO_ROOT)
cfg_ok <- all(vapply(cfg, isTRUE, logical(1)))
cat("hub config valid:", cfg_ok, "\n"); if (!cfg_ok) print(cfg)

files <- sub(paste0("^", file.path(REPO_ROOT, "model-output"), "/"), "",
             list.files(file.path(REPO_ROOT, "model-output"), pattern = "\\.parquet$", recursive = TRUE, full.names = TRUE))
n_sample <- as.integer(Sys.getenv("FSN_VALIDATE_SAMPLE", "0"))
if (n_sample > 0) {
  set.seed(1)
  d <- data.table(file = files, model = dirname(files))
  files <- d[, .SD[sample(.N, min(.N, max(1L, ceiling(n_sample / uniqueN(d$model)))))], by = model]$file
}
message("validating ", length(files), " files")

check_one <- function(f) {
  v <- tryCatch(validate_submission(hub_path = REPO_ROOT, file_path = f, skip_submit_window_check = TRUE,
                                    skip_check_config = TRUE),
                error = function(e) e)
  if (inherits(v, "error")) return(data.table(file = f, ok = FALSE, failed = paste("ERROR:", conditionMessage(v))))
  bad <- names(v)[vapply(v, function(x) inherits(x, c("check_failure", "check_error", "check_exec_error")), logical(1))]
  data.table(file = f, ok = length(bad) == 0, failed = paste(bad, collapse = ";"),
             messages = paste(vapply(v[bad], function(x) conditionMessage(x), ""), collapse = " | "))
}
t0 <- Sys.time()
res <- rbindlist(mclapply(files, check_one, mc.cores = max(1L, detectCores() - 2L)), fill = TRUE)
message("validated in ", round(difftime(Sys.time(), t0, units = "mins"), 1), " min")
fwrite_csv(res, if (n_sample > 0) "hubverse-validation-sample.csv" else "hubverse-validation.csv")

cat("\n=== hubValidations ===\n")
print(res[, .(files = .N, passed = sum(ok), failed = sum(!ok))])
if (res[ok == FALSE, .N]) print(res[ok == FALSE, .N, by = .(failed, msg = substr(messages, 1, 160))][order(-N)][1:min(10, .N)])

# ---- hubData: the whole hub loads and row counts match -------------------------------------
hub <- connect_hub(REPO_ROOT, file_format = "parquet", skip_checks = TRUE)
counts <- hub |> count(model_id, output_type) |> collect() |> as.data.table()
stats <- fread(file.path(VALIDATION_DIR, "conversion-stats.csv"))
exp <- stats[, .(pmf = sum(pmf_rows), median = sum(median_rows)), by = model_id]
got <- dcast(counts, model_id ~ output_type, value.var = "n", fill = 0)
cmp <- merge(exp, got, by = "model_id", all = TRUE, suffixes = c("_expected", "_hub"))
cmp[, ok := pmf_expected == pmf_hub & median_expected == median_hub]
cat("\nhubData load: models", nrow(cmp), " row counts match:", all(cmp$ok, na.rm = FALSE), "\n")
if (!all(cmp$ok)) print(cmp[ok == FALSE | is.na(ok)])
