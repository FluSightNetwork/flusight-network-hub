# Step 01: catalogue every version of every forecast file in the source repo's history.
#
# Output (committed):
#   validation/source-refs.csv     branches/tags/PR refs with their commits
#   validation/source-history.csv  one row per (commit, path) add/modify/delete of a forecast CSV
#   validation/source-pin.csv      the pinned commits used to define the training record
#
# "Forecast file" = any CSV under model-forecasts/ whose name contains an EWxx-YYYY stamp.

source("src/00_config.R")
stopifnot_source()

# ---- refs -------------------------------------------------------------------
refs <- fread(text = git("for-each-ref", "--format=%(refname)\t%(objectname)\t%(creatordate:iso-strict)"),
              sep = "\t", header = FALSE, col.names = c("ref", "sha", "date"))
refs[, kind := fifelse(grepl("^refs/heads/", ref), "branch",
                fifelse(grepl("^refs/tags/", ref), "tag",
                fifelse(grepl("^refs/pull/", ref), "pull", "other")))]
fwrite_csv(refs, "source-refs.csv")

# ---- history ------------------------------------------------------------------
read_log <- function(rev_args) {
  raw <- git("log", rev_args, "--no-renames", "--raw", "--no-abbrev",
             "--format=C\t%H\t%aI\t%cI\t%s", "--", "model-forecasts")
  is_c <- startsWith(raw, "C\t")
  grp <- cumsum(is_c)
  hdr <- tstrsplit(raw[is_c], "\t", fixed = TRUE, keep = 2:5)
  commits <- data.table(grp = seq_along(hdr[[1]]), commit = hdr[[1]], author_date = hdr[[2]],
                        commit_date = hdr[[3]], subject = hdr[[4]])
  ch <- raw[!is_c & startsWith(raw, ":")]
  ch_grp <- grp[!is_c & startsWith(raw, ":")]
  # ":100644 100644 <old> <new> M\tpath"
  meta <- tstrsplit(sub("\t.*$", "", ch), " ", fixed = TRUE)
  out <- data.table(grp = ch_grp, old_blob = meta[[3]], blob = meta[[4]], status = meta[[5]],
                    path = sub("^[^\t]*\t", "", ch))
  merge(out, commits, by = "grp")[, grp := NULL][]
}

hist_main <- read_log(c("--branches", "--tags"))
hist_all <- read_log("--all")

is_forecast <- function(p) startsWith(p, "model-forecasts/") & grepl("\\.csv$", p) & grepl("EW0*[0-9]{1,2}[-_][0-9]{4}", basename(p))
hist_main <- hist_main[is_forecast(path)]
hist_all <- hist_all[is_forecast(path)]

hist_main[, source_refs := "branches_tags"]
pr_only <- fsetdiff(hist_all[, .(commit, path, blob, status)], hist_main[, .(commit, path, blob, status)])
pr_only <- merge(pr_only, unique(hist_all[, .(commit, author_date, commit_date, subject)]), by = "commit")
pr_only[, source_refs := "pull_only"]
hist <- rbind(hist_main[, .(commit, author_date, commit_date, subject, status, path, blob, old_blob = NULL, source_refs)],
              pr_only[, .(commit, author_date, commit_date, subject, status, path, blob, source_refs)], fill = TRUE)

# commits reachable from master HEAD (first-parent or not)
on_master <- git("rev-list", SOURCE_MASTER_SHA)
hist[, on_master_history := commit %in% on_master]

# parse location within the repo
parts <- tstrsplit(hist$path, "/", fixed = TRUE)
hist[, collection := parts[[2]]]
hist[, file := basename(path)]
hist[, dir := sub("^model-forecasts/[^/]+/", "", dirname(path))]
hist[, c("ew", "ew_year") := parse_ew(file)]
setorder(hist, path, author_date, commit)
fwrite_csv(hist, "source-history.csv")

# ---- pin: the commit that rebuilt all cv-ensemble files on 2019-10-25 -------------
cv_build <- unique(hist[source_refs == "branches_tags" & on_master_history &
                        collection == "cv-ensemble-models" & status %in% c("A", "M") &
                        substr(author_date, 1, 10) == "2019-10-25",
                        .(commit, author_date, subject, n_files = .N), by = commit])
print(cv_build)
stopifnot(nrow(cv_build) >= 1)
pin_commit <- cv_build[which.max(n_files), commit]

pin <- data.table(
  name = c("master_head", "training_pin"),
  commit = c(SOURCE_MASTER_SHA, pin_commit),
  description = c("source master HEAD (2020-05-04)",
                  "commit that rebuilt all cv-ensemble files; defines the training backcasts of component models")
)
pin[, date := vapply(commit, function(c) git("show", "-s", "--format=%aI", c), "")]
fwrite_csv(pin, "source-pin.csv")

# ---- summary --------------------------------------------------------------------
cat("\nforecast-file history rows:", nrow(hist), "\n")
print(hist[, .N, by = .(source_refs, status)])
cat("distinct (path, blob) versions:", uniqueN(hist[status != "D", .(path, blob)]), "\n")
cat("distinct blobs only reachable via PR refs:",
    uniqueN(setdiff(hist[source_refs == "pull_only" & status != "D", blob],
                    hist[source_refs == "branches_tags", blob])), "\n")
