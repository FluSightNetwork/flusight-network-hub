# Compute FluSight 2016-style truths from an ILINet snapshot, mirroring FSN's scripts/calculate-targets.R
# (epiforecast flusight2016 targets on the ROUNDED trajectory):
#   k wk ahead   rounded wILI of the week origin + k
#   peak %       max rounded wILI over in-season weeks (MMWR 40..20)
#   peak week    in-season week(s) attaining that max (several if tied)
#   onset        first in-season week starting a run of 3 consecutive weeks with rounded wILI >= baseline;
#                "none" if there is no such run
# Data: ILINet as of issue (y0+1)28; HHS regions before 2013/14 use issue 201352 (as FSN did).
# Baselines: CDC regional baselines (FluSight R package `past_baselines`; year = season start year).
#
# Used by step 08 for 2019/20, and by validate_truths() to check the method against FSN's truths.

source("src/00_config.R")
ILI_DIR <- file.path(REPO_ROOT, "auxiliary-data", "ilinet")
BASELINES <- fread(file.path(SRC_DIR, "baselines.csv"))

# Season end (last in-season MMWR week) by season start year. FluSight used week 20.
# 2019/20 is cut at EW09-2020 (week ending 2020-02-29) so that COVID-19-affected spring weeks are not
# scored as onset/peak (user decision 2026-11-23). Weekly targets are not affected.
SEASON_END_WEEK <- c("2019" = 9L)
season_end_week <- function(y0) { w <- SEASON_END_WEEK[as.character(y0)]; if (is.na(w)) 20L else unname(w) }

season_data <- function(y0, location) {
  iss <- if (location != "US National" && y0 < 2013) 201352L else as.integer(sprintf("%d28", y0 + 1))
  loc <- location
  d <- fread(file.path(ILI_DIR, sprintf("issue-%d.csv", iss)))[location == loc]
  d[, `:=`(ey = epiweek %/% 100L, ew = epiweek %% 100L)]
  d[, week_end := mmwr_week_end(ey, ew)]
  d[, r := round(wili, 1)]
  d[, inseason := week_end >= mmwr_week_end(y0, 40L) & week_end <= mmwr_week_end(y0 + 1L, season_end_week(y0))]
  setorder(d, week_end)
  d[, issue_used := iss]
  d
}

seasonal_truths <- function(y0, location) {
  d <- season_data(y0, location)[inseason == TRUE]
  loc <- location; yr <- y0
  b <- BASELINES[year == yr & location == loc, value]
  stopifnot(length(b) == 1)
  above <- d$r >= b
  n <- length(above)
  run3 <- above & c(above[-1], FALSE) & c(above[-(1:2)], FALSE, FALSE)
  onset <- if (any(run3)) as.character(d$ew[which(run3)[1]]) else "none"
  pk <- max(d$r)
  data.table(season = sprintf("%d/%d", y0, y0 + 1), location = location,
             target = c("Season onset", rep("Season peak week", sum(d$r == pk)), "Season peak percentage"),
             valid = c(onset, as.character(d$ew[d$r == pk]), sprintf("%.1f", pk)),
             baseline = b, issue_used = d$issue_used[1], season_end_week = season_end_week(y0))
}

weekly_truths <- function(y0, location) {
  d <- season_data(y0, location)
  # each season supplies only its own weeks (MMWR y0-30 .. (y0+1)-29); fallback snapshots overlap seasons
  d <- d[week_end >= mmwr_week_end(y0, 30L) & week_end < mmwr_week_end(y0 + 1L, 30L)]
  d[, .(target_end_date = week_end, location, observation = r, issue_used)]
}

LOCATIONS <- c("US National", paste("HHS Region", 1:10))

# Compare recomputed truths with FSN's target-multivals.csv for 2010/11-2018/19.
validate_truths <- function() {
  tm <- fread(text = git("show", paste0(SOURCE_MASTER_SHA, ":scores/target-multivals.csv")), colClasses = "character")
  setnames(tm, c("year", "cal_week", "season", "model_week", "location", "target", "valid"))
  fsn_seasonal <- unique(tm[target %like% "^Season", .(season, location, target, valid)])
  mine <- rbindlist(lapply(2010:2018, function(y) rbindlist(lapply(LOCATIONS, function(l) seasonal_truths(y, l)))))
  norm <- function(x) ifelse(x == "none", x, sub("\\.0$", "", sprintf("%.1f", as.numeric(x))))
  fsn_seasonal[, v := norm(valid)]; mine[, v := norm(valid)]
  key <- c("season", "location", "target")
  a <- fsn_seasonal[, .(fsn = paste(sort(v), collapse = ",")), by = key]
  b <- mine[, .(recomputed = paste(sort(v), collapse = ",")), by = key]
  s <- merge(a, b, by = key, all = TRUE)[, match := fsn == recomputed]

  wk <- tm[grepl("wk ahead", target)]
  wk[, target_end_date := mmwr_week_end(as.integer(year), as.integer(cal_week)) + 7L * as.integer(substr(target, 1, 1))]
  fsn_w <- unique(wk[, .(target_end_date, location, fsn = as.numeric(valid))])
  mine_w <- unique(rbindlist(lapply(2010:2018, function(y) rbindlist(lapply(LOCATIONS, function(l) weekly_truths(y, l))))),
                   by = c("target_end_date", "location"))
  w <- merge(fsn_w, mine_w, by = c("target_end_date", "location"))[, match := abs(fsn - observation) < 1e-9]
  list(seasonal = s, weekly = w)
}
