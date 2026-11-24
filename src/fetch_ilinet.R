# Fetch ILINet (wILI) snapshots used to compute truths, from the Delphi Epidata API (fluview).
# FSN computed truths from data as of issue YYYY28 after each season (scripts/calculate-targets.R,
# eval.issue); HHS regions before 2013/14 have no such issue, and FSN used issue 201352 instead.
# Snapshots are saved for provenance: auxiliary-data/ilinet/issue-<issue>.csv

source("src/00_config.R"); suppressPackageStartupMessages(library(jsonlite))
OUT <- file.path(REPO_ROOT, "auxiliary-data", "ilinet"); dir.create(OUT, recursive = TRUE, showWarnings = FALSE)
REGIONS <- c("nat", paste0("hhs", 1:10))

fetch <- function(issue, ew_from, ew_to) {
  f <- file.path(OUT, sprintf("issue-%d.csv", issue))
  if (file.exists(f)) return(fread(f))
  url <- sprintf("https://api.delphi.cmu.edu/epidata/fluview/?regions=%s&epiweeks=%d-%d&issues=%d",
                 paste(REGIONS, collapse = ","), ew_from, ew_to, issue)
  r <- fromJSON(url)
  if (r$result != 1) { warning("issue ", issue, ": ", r$message); return(NULL) }
  d <- as.data.table(r$epidata)[, .(region, epiweek, issue, release_date, lag, wili, ili, num_ili, num_patients, num_providers)]
  d[, location := fifelse(region == "nat", "US National", paste("HHS Region", sub("hhs", "", region)))]
  fwrite(d, f); Sys.sleep(1)
  d
}

for (y in 2010:2019) {
  fetch(as.integer(sprintf("%d28", y + 1)), as.integer(sprintf("%d30", y)), as.integer(sprintf("%d28", y + 1)))
}
fetch(201352L, 201030L, 201352L)   # FSN's fallback issue for HHS regions before 2013/14
cat(paste(list.files(OUT), collapse = "\n"), "\n")
