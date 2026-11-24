# Figure: which model IDs have forecasts in which seasons (number of weekly files per model and season).
# Reads the file map (validation/file-map.csv + file-map-repaired.csv); writes validation/model-coverage.png.
#   Rscript src/plot_coverage.R

source("src/00_config.R")
suppressPackageStartupMessages(library(ggplot2))

fm <- load_file_map()
x <- fm[, .(n = .N, rt = sum(is_real_time)), by = .(model_id, season)]
x[, kind := factor(fifelse(rt == n, "all real-time", fifelse(rt == 0, "none real-time", "some real-time")),
                   levels = c("all real-time", "some real-time", "none real-time"))]
x[, season := paste0(substr(season, 3, 4), "/", substr(season, 8, 9))]
x[, group := fcase(startsWith(model_id, "FSNetwork-"), "FSN ensemble builds",
                   model_id == "FluSight-unweighted_avg", "CDC",
                   default = "Component models")]
x[, group := factor(group, levels = c("Component models", "CDC", "FSN ensemble builds"))]
x[, model_id := factor(model_id, levels = rev(sort(unique(model_id))))]

p <- ggplot(x, aes(season, model_id, fill = kind)) +
  geom_tile(colour = "white", linewidth = 0.4) +
  geom_text(aes(label = n), size = 2.2, colour = "grey15") +
  facet_grid(group ~ ., scales = "free_y", space = "free_y") +
  scale_fill_manual(values = c("all real-time" = "#E69F00", "some real-time" = "#F3CF80", "none real-time" = "#9ECAE1"),
                    name = "Forecasts made in real time:") +
  labs(x = "Season", y = NULL,
       title = "FluSight Network hub: model coverage by season",
       subtitle = "Label = number of weekly forecast files (origin dates). Real-time flag: is_real_time in auxiliary-data/file-provenance.csv") +
  theme_minimal(base_size = 9) +
  theme(legend.position = "top", panel.grid = element_blank(), strip.text.y = element_text(angle = 0, hjust = 0),
        plot.title.position = "plot")

out <- file.path(VALIDATION_DIR, "model-coverage.png")
ggsave(out, p, width = 8, height = 13, dpi = 150, bg = "white")
message("wrote validation/model-coverage.png (", uniqueN(x$model_id), " model IDs)")
