# Resolve FSN's tied peak weeks (user decision 2026-11-23: use the unrounded maximum).
# FSN's truths (scores/target-multivals.csv) list several peak weeks where rounded wILI ties.
# For each tie, take the week with the highest unrounded wILI in ILINet (Delphi Epidata API,
# latest issue at the time of the query). Output: src/peak_week_ties.csv (committed input to step 08).
source("src/00_config.R"); suppressPackageStartupMessages(library(jsonlite)); options(width = 220)
url <- paste0("https://api.delphi.cmu.edu/epidata/fluview/?regions=nat,", paste0("hhs", 1:10, collapse = ","),
              "&epiweeks=201030-202030")
fv <- as.data.table(fromJSON(url)$epidata)
fv[, location := fifelse(region == "nat", "US National", paste("HHS Region", sub("hhs", "", region)))]
fv[, `:=`(ey = epiweek %/% 100L, ew = epiweek %% 100L)]
tm <- fread(text = git("show", "refs/heads/master:scores/target-multivals.csv"))
setnames(tm, c("year", "cal_week", "season", "model_week", "location", "target", "valid"))
pk <- tm[target == "Season peak week", .(valid = sort(unique(as.integer(valid)))), by = .(season, location)]
ties <- pk[, .(weeks = list(valid), n = .N), by = .(season, location)][n > 1]
out <- rbindlist(lapply(seq_len(nrow(ties)), function(i) {
  s <- ties$season[i]; y0 <- as.integer(substr(s, 1, 4)); w <- ties$weeks[[i]]
  yy <- ifelse(w >= 30, y0, y0 + 1L); keys <- paste(yy, w); loc <- ties$location[i]
  x <- fv[location == loc & paste(ey, ew) %in% keys, .(week = ew, year = ey, wili, issue)]
  x <- x[match(keys, paste(x$year, x$week))]
  x[, `:=`(season = s, location = loc, week_end = mmwr_week_end(year, week), rounded = round(wili, 1))]
  x[, unrounded_max := wili == max(wili)]
  x
}))
setcolorder(out, c("season", "location", "week", "week_end", "rounded", "wili", "unrounded_max", "issue"))
print(out[, .(season, location, week, week_end, rounded, wili = round(wili, 4), highest_unrounded = unrounded_max, issue)])
out[, `:=`(queried = as.character(Sys.Date()), source = "Delphi Epidata fluview, wili")]
out[, chosen := unrounded_max]
fwrite(out, file.path(SRC_DIR, "peak_week_ties.csv"))
message("wrote src/peak_week_ties.csv")
