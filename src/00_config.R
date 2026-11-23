# Shared configuration and helpers for the conversion pipeline.
# Every numbered script sources this file first.

suppressPackageStartupMessages({
  library(data.table)
})

# ---- paths ----------------------------------------------------------------
# Repo root = parent of src/. Scripts are run as `Rscript src/NN_name.R` from the root.
REPO_ROOT <- normalizePath(Sys.getenv("FSN_REPO_ROOT", "."), mustWork = TRUE)

# Bare mirror clone of https://github.com/FluSightNetwork/cdc-flusight-ensemble
# (create with: git clone --mirror <url> .cache/cdc-flusight-ensemble.git)
SOURCE_GIT <- Sys.getenv("FSN_SOURCE_GIT", file.path(REPO_ROOT, ".cache", "cdc-flusight-ensemble.git"))

# Intermediate (non-committed) build outputs
WORK_DIR <- Sys.getenv("FSN_WORK_DIR", file.path(REPO_ROOT, ".cache", "work"))

VALIDATION_DIR <- file.path(REPO_ROOT, "validation")
SRC_DIR <- file.path(REPO_ROOT, "src")

SOURCE_URL <- "https://github.com/FluSightNetwork/cdc-flusight-ensemble"
SOURCE_MASTER_SHA <- "8c3100af015cae2fb43db823c3f61e7e6a7d59ea"  # master HEAD, 2020-05-04

dir.create(WORK_DIR, recursive = TRUE, showWarnings = FALSE)
dir.create(VALIDATION_DIR, recursive = TRUE, showWarnings = FALSE)

# ---- git helpers ----------------------------------------------------------
git <- function(..., stdout = TRUE) {
  args <- c("--git-dir", SOURCE_GIT, ...)
  out <- suppressWarnings(system2("git", shQuote(args), stdout = stdout, stderr = FALSE))
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) stop("git failed: git ", paste(args, collapse = " "))
  out
}

stopifnot_source <- function() {
  if (!dir.exists(SOURCE_GIT)) stop("Source mirror not found at ", SOURCE_GIT)
  head <- git("rev-parse", "refs/heads/master")
  if (head != SOURCE_MASTER_SHA) {
    stop("Source master is ", head, " but pipeline is pinned to ", SOURCE_MASTER_SHA)
  }
  invisible(TRUE)
}

# ---- MMWR helpers -----------------------------------------------------------
# Saturday ending MMWR week `ew` of MMWR year `ey`.
mmwr_week_end <- function(ey, ew) {
  jan4 <- as.Date(sprintf("%d-01-04", ey))
  wk1_start <- jan4 - as.integer(format(jan4, "%w"))  # Sunday on/before Jan 4
  wk1_start + 7L * (ew - 1L) + 6L
}

# Number of MMWR weeks in MMWR year `ey` (52 or 53).
mmwr_weeks_in_year <- function(ey) {
  as.integer((mmwr_week_end(ey + 1L, 1L) - mmwr_week_end(ey, 1L)) / 7)
}

# Season label ("2015/2016") for a forecast origin date.
season_of <- function(d) {
  y <- as.integer(format(d, "%Y")); m <- as.integer(format(d, "%m"))
  ifelse(m >= 8L, sprintf("%d/%d", y, y + 1L), sprintf("%d/%d", y - 1L, y))
}

# Parse "EWxx-YYYY" (tolerating EW002-2020, EW01_2010) from a file name.
parse_ew <- function(fname) {
  m <- regmatches(fname, regexec("EW0*([0-9]{1,2})[-_]([0-9]{4})", fname))
  data.table(
    ew = vapply(m, function(x) if (length(x)) as.integer(x[2]) else NA_integer_, 1L),
    ew_year = vapply(m, function(x) if (length(x)) as.integer(x[3]) else NA_integer_, 1L)
  )
}

fwrite_csv <- function(x, name) {
  path <- file.path(VALIDATION_DIR, name)
  fwrite(x, path)
  message("wrote ", sub(paste0(REPO_ROOT, "/"), "", path), " (", nrow(x), " rows)")
  invisible(path)
}

# The full conversion set: file-map.csv plus repaired cv ensembles (step 05), if present.
load_file_map <- function() {
  fm <- fread(file.path(VALIDATION_DIR, "file-map.csv"))
  rp <- file.path(VALIDATION_DIR, "file-map-repaired.csv")
  if (file.exists(rp)) fm <- rbind(fm, fread(rp)[, names(fm), with = FALSE])
  fm[, repaired := startsWith(blob, "repaired-")]
  fm[]
}
