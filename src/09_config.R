# Step 09: write hub-config/ (tasks.json, admin.json, model-metadata-schema.json).
#
# tasks.json is generated from the converted model-output (round IDs, week-bin dates per season),
# using hubAdmin's builders so the structure is schema-valid by construction.
# admin.json: hub identity as set by the maintainer (2026-11-23).

source("src/00_config.R")
suppressPackageStartupMessages({ library(arrow); library(dplyr); library(hubAdmin); library(jsonlite) })
SCHEMA <- "v6.0.0"
options(hubAdmin.schema_version = SCHEMA)
CFG_DIR <- file.path(REPO_ROOT, "hub-config"); dir.create(CFG_DIR, showWarnings = FALSE)

LOCATIONS <- c("US National", paste("HHS Region", 1:10))
ILI_BINS <- sprintf("%.1f", seq(0, 13, by = 0.1))

# ---- data-driven values ---------------------------------------------------------------------
sch <- arrow::schema(origin_date = date32(), location = utf8(), target = utf8(), horizon = int32(),
                     target_end_date = date32(), output_type = utf8(), output_type_id = utf8(), value = float64())
ds <- open_dataset(file.path(REPO_ROOT, "model-output"), format = "parquet", schema = sch)
rounds <- ds |> distinct(origin_date, target) |> collect() |> as.data.table()
rounds[, season := season_of(origin_date)]
wk_ids <- ds |> filter(target %in% c("season onset wk", "season peak wk")) |>
  distinct(origin_date, target, output_type_id) |> collect() |> as.data.table()
wk_ids[, season := season_of(origin_date)]
ili_ids <- ds |> filter(output_type == "pmf", target %in% c("ili perc", "season peak perc")) |>
  distinct(output_type_id) |> collect()
stopifnot(setequal(ili_ids$output_type_id, ILI_BINS))

all_origins <- sort(unique(format(rounds$origin_date)))
ili_origins <- sort(unique(format(rounds[target == "ili perc", origin_date])))
pk_origins <- sort(unique(format(rounds[target == "season peak perc", origin_date])))
ted <- ds |> filter(target == "ili perc") |> distinct(target_end_date) |> collect()
all_ted <- sort(unique(format(ted$target_end_date)))

# ---- tasks.json (written as plain lists; validated with hubAdmin below) ---------------------------
tid <- function(optional) list(required = NULL, optional = as.list(optional))
tid_null <- list(required = NULL, optional = NULL)
pmf_ot <- function(ids) list(output_type_id = list(required = as.list(ids)), is_required = FALSE,
                             value = list(type = "double", minimum = 0, maximum = 1))
median_ot <- list(output_type_id = list(required = NULL), is_required = FALSE, value = list(type = "double", minimum = 0, maximum = 100))
tmeta <- function(id, name, units, type, step, desc, time_unit = NULL) {
  x <- list(target_id = id, target_name = name, target_units = units, target_keys = list(target = id),
            description = desc, target_type = type, is_step_ahead = step)
  if (!is.null(time_unit)) x$time_unit <- time_unit
  x
}
# target first, for readability (hubValidations matches columns by name, not position)
task_ids <- function(origins, target, horizon = NULL, ted = NULL) list(
  target = tid(target), origin_date = tid(origins), location = tid(LOCATIONS),
  horizon = if (is.null(horizon)) tid_null else tid(horizon),
  target_end_date = if (is.null(ted)) tid_null else tid(ted))

# One round per season: with round_id_from_variable, all model tasks in a round must list the same
# origin_date values, and each season has its own week-bin dates.
rounds[, season := season_of(origin_date)]
make_round <- function(s) {
  r_orig <- sort(unique(format(rounds[season == s, origin_date])))
  r_ted <- ds |> filter(target == "ili perc") |> distinct(origin_date, target_end_date) |> collect() |> as.data.table()
  r_ted <- sort(unique(format(r_ted[season_of(origin_date) == s, target_end_date])))
  tgts <- unique(rounds[season == s, target])
  mts <- list()
  if ("ili perc" %in% tgts) mts[[length(mts) + 1]] <- list(
    task_ids = task_ids(r_orig, "ili perc", 1:4, r_ted),
    output_type = list(pmf = pmf_ot(ILI_BINS), median = median_ot),
    target_metadata = list(tmeta("ili perc", "Weekly weighted ILI percentage", "percent", "ordinal", TRUE,
      paste("Weighted influenza-like illness (wILI) percentage reported through ILINet for the week ending target_end_date,",
            "rounded to one decimal. pmf bins are labelled by their left edge; \"13.0\" is the open bin [13, 100].",
            "median is computed from the pmf (see README)."), time_unit = "week")))
  if ("season peak perc" %in% tgts) mts[[length(mts) + 1]] <- list(
    task_ids = task_ids(r_orig, "season peak perc"),
    output_type = list(pmf = pmf_ot(ILI_BINS)),
    target_metadata = list(tmeta("season peak perc", "Season peak weighted ILI percentage", "percent", "ordinal", FALSE,
      "Highest weekly wILI percentage of the season, rounded to one decimal. Bins as for ili perc.")))
  for (tg in c("season onset wk", "season peak wk")) {
    x <- wk_ids[season == s & target == tg]
    if (!nrow(x)) next
    dates <- sort(unique(setdiff(x$output_type_id, "none")))
    ids <- if (tg == "season onset wk") c(dates, "none") else dates
    mts[[length(mts) + 1]] <- list(
      task_ids = task_ids(r_orig, tg),
      output_type = list(pmf = pmf_ot(ids)),
      target_metadata = list(tmeta(tg, if (tg == "season onset wk") "Season onset week" else "Season peak week", "week",
        if (tg == "season onset wk") "nominal" else "date", FALSE,
        if (tg == "season onset wk")
          "MMWR week (labelled by its Saturday end date) when wILI first reaches the regional baseline for 3 consecutive weeks; \"none\" = no onset."
        else "MMWR week (labelled by its Saturday end date) with the highest wILI of the season.")))
  }
  list(round_id_from_variable = TRUE, round_id = "origin_date", round_name = s,
       model_tasks = mts, submissions_due = list(relative_to = "origin_date", start = -400L, end = 400L))
}
seasons <- sort(unique(rounds$season))
week_tasks <- seasons  # (for the summary line)

tasks <- list(
  schema_version = sprintf("https://raw.githubusercontent.com/hubverse-org/schemas/main/%s/tasks-schema.json", SCHEMA),
  rounds = lapply(seasons, make_round),
  output_type_id_datatype = "character",
  derived_task_ids = list("target_end_date"))
write_json(tasks, file.path(CFG_DIR, "tasks.json"), auto_unbox = TRUE, pretty = TRUE, null = "null", digits = NA)

# ---- admin.json ----------------------------------------------------------------------------------
admin <- list(
  schema_version = sprintf("https://raw.githubusercontent.com/hubverse-org/schemas/main/%s/admin-schema.json", SCHEMA),
  name = "FluSight Network Forecast Archive",
  maintainer = "Reich Lab",
  contact = list(name = "Nick Reich", email = "nick@umass.edu"),
  repository = list(host = "github", owner = "FluSightNetwork", name = "flusight-network-hub"),
  file_format = list("parquet"),
  timezone = "US/Eastern")
write_json(admin, file.path(CFG_DIR, "admin.json"), auto_unbox = TRUE, pretty = TRUE)

# ---- model-metadata-schema.json --------------------------------------------------------------------
str_prop <- function(desc) list(type = "string", description = desc)
mms <- list(
  `$schema` = "https://json-schema.org/draft/2020-12/schema",
  title = "Schema for FluSight Network archive model metadata",
  type = "object",
  properties = list(
    team_abbr = list(type = "string", pattern = "^[a-zA-Z0-9_]+$", description = "Team abbreviation"),
    model_abbr = list(type = "string", pattern = "^[a-zA-Z0-9_]+$", description = "Model abbreviation"),
    team_name = str_prop("Team name as given in the source repository"),
    model_name = str_prop("Model name as given in the source repository"),
    model_contributors = list(type = "array", description = "Team members listed in the source metadata.txt",
                              items = list(type = "object", properties = list(name = list(type = "string")),
                                           required = list("name"))),
    real_time_seasons = list(type = "array", items = list(type = "string"), description = paste(
      "Seasons with forecasts made in real time (first committed no more than 3 days after the FluSight due date).",
      "A real-time season can still contain a few rounds that are not real-time; the exact flag per round is",
      "is_real_time in auxiliary-data/file-provenance.csv.")),
    fsn_ensemble_component_seasons = list(type = "array", items = list(type = "string"), description = paste(
      "Operational seasons in which this model was a component of the FluSight Network ensemble",
      "(listed in FSN's weights for that season's ensemble build). Component models only.")),
    version_of = str_prop(paste("For models retrained between seasons: the source model this ID is one version of.",
                                "Each version holds that model's backcasts and its real-time forecasts.")),
    version_note = str_prop("What distinguishes this version (retraining commit, seasons, FSN ensemble use)."),
    paired_model_id = list(type = c("string", "null"),
                           description = "Ensembles only: the repaired copy of this ensemble build (FSNetwork-<ABBR>_<YYYY_YY>_repaired), or for a repaired copy the original."),
    source_dirs = list(type = "array", items = list(type = "string"),
                       description = "Source directories (FluSightNetwork/cdc-flusight-ensemble unless prefixed with another repository)."),
    seasons = list(type = "array", items = list(type = "string"), description = "Seasons with at least one forecast."),
    this_model_is_an_ensemble = list(type = "boolean", description = paste(
      "From the source metadata.txt, self-reported by each team. FSN's guidelines (guidelines.md) define it only as",
      "\"whether or not the model itself is a type of ensemble model\" (template: this_model_is_an_ensemble: TRUE/FALSE).")),
    real_time_start_season = list(type = c("string", "null")),
    methods = str_prop("Methods text from the source metadata.txt"),
    data_inputs = str_prop("Data sources from the source metadata.txt"),
    designated_model = list(type = "boolean", description = "Not used in this archive; always false."),
    notes = str_prop("Archive notes (provenance, exceptions)")),
  required = list("team_abbr", "model_abbr", "real_time_seasons", "designated_model"),
  additionalProperties = FALSE)
write_json(mms, file.path(CFG_DIR, "model-metadata-schema.json"), auto_unbox = TRUE, pretty = TRUE, null = "null")

res <- validate_hub_config(hub_path = REPO_ROOT)
print(res)
cat("rounds (seasons):", length(seasons), "| origin dates:", length(all_origins), "\n")
