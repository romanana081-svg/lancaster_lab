# curves_from_readout.R — slide-ready cumulative-incidence curves drawn from a SURVIVAL READOUT.
#
# WHY THIS EXISTS: `run_survival_curves()` writes figures 14/15/17 inside the Workbench, where the
# PNGs then have to be fetched out of the bucket. The readout text, by contrast, leaves the Workbench
# by copy-paste (H-006 aggregate-only). This redraws the same three curves from the readout numbers
# alone, on a laptop, so a deck can be built without a bucket round-trip.
#
# WHAT IT IS NOT: it is not a re-analysis. Every number below is transcribed from a readout; nothing
# is recomputed from participant data, and this script never touches the CDR. If the readout changes,
# edit `READOUT` and re-run.
#
# THE HONESTY CONSTRAINT: a readout carries the KM estimate at the reported HORIZONS, not the step
# function between them. So the horizons are drawn as points with their confidence intervals, and the
# segments joining them are visibly just segments. Drawing a smooth or stepped curve through two
# points would assert a shape the readout does not contain. The full step curve is figure 14.
#
#   Rscript src/figures/curves_from_readout.R

suppressPackageStartupMessages({ library(ggplot2); library(dplyr) })

OUTDIR <- "reports/readout_curves"

# --- the readout ----------------------------------------------------------------------------------
# Transcribed from SURVIVAL READOUT 2026-08-06 (identical to 2026-08-04).
READOUT <- list(
  landmark = "2023-01-01", cutoff = "2025-01-01", followup_years = 2.00,
  n_at_risk = 50078, n_broad = 2879, n_acute = 576,
  n_female = 30002, n_male = 18427)

# years 3-5 are DELIBERATELY ABSENT. The readout reports them, but follow-up is 2.00 years, so those
# rows are survfit(extend = TRUE) carrying the year-2 estimate forward on n_risk = 0. Plotted, they
# read as "incidence plateaus after two years", which is a claim the data cannot make.
est <- tribble(
  ~panel,   ~series,       ~years, ~cuminc, ~lo,  ~hi,
  "all",    "All ASCVD",    0,     0.00,    NA,   NA,
  "all",    "All ASCVD",    1,     3.29,    3.14, 3.45,
  "all",    "All ASCVD",    2,     5.75,    5.54, 5.95,

  "sex",    "Female",       0,     0.00,    NA,   NA,
  "sex",    "Female",       1,     3.01,    2.82, 3.20,
  "sex",    "Female",       2,     5.21,    4.97, 5.46,
  "sex",    "Male",         0,     0.00,    NA,   NA,
  "sex",    "Male",         1,     3.75,    3.48, 4.01,
  "sex",    "Male",         2,     6.61,    6.26, 6.96,

  "def",    "All ASCVD",    0,     0.00,    NA,   NA,
  "def",    "All ASCVD",    1,     3.29,    3.14, 3.45,
  "def",    "All ASCVD",    2,     5.75,    5.54, 5.95,
  "def",    "Acute only",   0,     0.00,    NA,   NA,
  "def",    "Acute only",   1,     0.69,    0.62, 0.77,
  "def",    "Acute only",   2,     1.15,    1.05, 1.24)

# --- palette & chrome (dataviz reference instance, light surface) ---------------------------------
SURFACE <- "#fcfcfb"; INK <- "#0b0b0b"; INK2 <- "#52514e"; MUTED <- "#898781"
GRID    <- "#e1e0d9"; AXIS <- "#c3c2b7"
S1 <- "#2a78d6"  # categorical slot 1 - blue
S2 <- "#eb6834"  # categorical slot 2 - orange

# Hard-wrapped, not left to the renderer: ggplot does not wrap captions, it clips them, and a caveat
# that loses its last clause to the plot edge is worse than no caveat.
CAVEAT <- paste(
  "Preliminary. Death not modelled, so competing risk is treated as censoring (overstates incidence).",
  "ICD10CM only, so pre-2015 events are invisible.",
  "Everyone event-free is censored at the CDR cutoff rather than last contact (understates the rate).",
  "Points are the Kaplan-Meier estimates at the reported horizons with 95% CI; segments merely connect",
  "them - the step shape between horizons is figure 14.", sep = "\n")

theme_curve <- function() {
  theme_minimal(base_size = 13, base_family = "Segoe UI") +
    theme(
      plot.background    = element_rect(fill = SURFACE, colour = NA),
      panel.background   = element_rect(fill = SURFACE, colour = NA),
      # hairline, solid, one shade off the surface - never dashed
      panel.grid.major.y = element_line(colour = GRID, linewidth = 0.3),
      panel.grid.major.x = element_blank(),
      panel.grid.minor   = element_blank(),
      axis.line.x        = element_line(colour = AXIS, linewidth = 0.4),
      axis.ticks         = element_blank(),
      axis.text          = element_text(colour = MUTED, size = 11),
      axis.title         = element_text(colour = INK2, size = 11),
      plot.title         = element_text(colour = INK, size = 15, face = "bold",
                                        margin = margin(b = 4)),
      plot.subtitle      = element_text(colour = INK2, size = 10.5, lineheight = 1.3,
                                        margin = margin(b = 14)),
      plot.caption       = element_text(colour = MUTED, size = 8, hjust = 0, lineheight = 1.25,
                                        margin = margin(t = 14)),
      plot.caption.position = "plot",
      plot.title.position   = "plot",
      legend.position    = "top",
      legend.justification = "left",
      legend.title       = element_blank(),
      legend.text        = element_text(colour = INK2, size = 11),
      legend.key         = element_blank(),
      plot.margin        = margin(18, 22, 14, 18))
}

#' One cumulative-incidence panel.
#'
#' @param cols named vector: series -> hex. Length 1 suppresses the legend (the title names the
#'   series, so a one-row legend box would be pure chrome).
curve_panel <- function(d, cols, title, subtitle, ymax) {
  # Order the legend by the order of `cols` (highest curve first), not alphabetically. Alphabetical
  # put "Acute only" above "All ASCVD" on the first render, so the legend read top-to-bottom in the
  # opposite order to the curves it labels.
  d$series <- factor(d$series, levels = names(cols))
  lab <- d %>% filter(years == max(years))
  p <- ggplot(d, aes(years, cuminc, colour = series)) +
    geom_line(linewidth = 0.8) +
    # CI first, so the marker sits on top of its own whisker
    geom_linerange(aes(ymin = lo, ymax = hi), linewidth = 0.8, na.rm = TRUE) +
    # 2px surface ring keeps a marker legible where it overlaps a whisker or another series
    geom_point(size = 3.4, stroke = 1.1, shape = 21, fill = SURFACE, na.rm = TRUE) +
    # direct-label the endpoint only - never a number on every point
    geom_text(data = lab, aes(label = sprintf("%.2f%%", cuminc)),
              hjust = 0, nudge_x = 0.07, size = 4, fontface = "bold", show.legend = FALSE) +
    scale_colour_manual(values = cols, breaks = names(cols)) +
    scale_x_continuous(breaks = 0:2, labels = c("landmark", "1 year", "2 years"),
                       limits = c(0, 2.42), expand = c(0, 0)) +
    scale_y_continuous(labels = function(x) paste0(x, "%"), limits = c(0, ymax),
                       expand = expansion(mult = c(0, 0.02))) +
    labs(title = title, subtitle = subtitle, caption = CAVEAT,
         x = NULL, y = "Cumulative incidence") +
    theme_curve()
  if (length(cols) < 2) p <- p + guides(colour = "none")
  p
}

# Two lines by construction. One long subtitle line is exactly what got clipped on the first render.
sub_line <- function(extra = NULL) {
  paste0(sprintf("Landmark %s → CDR cutoff %s (%.2f years) · %s at risk",
                 READOUT$landmark, READOUT$cutoff, READOUT$followup_years,
                 format(READOUT$n_at_risk, big.mark = ",")),
         if (!is.null(extra)) paste0("\n", extra) else "")
}

save_png <- function(p, file, w = 8.6, h = 6.0) {
  path <- file.path(OUTDIR, file)
  ggsave(path, p, width = w, height = h, dpi = 200, bg = SURFACE,
         device = if (requireNamespace("ragg", quietly = TRUE)) ragg::agg_png else NULL)
  message("wrote ", path)
}

if (!dir.exists(OUTDIR)) dir.create(OUTDIR, recursive = TRUE)

save_png(curve_panel(
  filter(est, panel == "all"), c("All ASCVD" = S1),
  "Cumulative incidence of ASCVD",
  sub_line(sprintf("%s incident events (D-016, all classes)",
                   format(READOUT$n_broad, big.mark = ","))),
  ymax = 7), "A_cumulative_incidence.png")

save_png(curve_panel(
  filter(est, panel == "sex"), c("Female" = S1, "Male" = S2),
  "Cumulative incidence of ASCVD, by sex",
  sub_line(sprintf("%s female · %s male at risk · PREVENT is sex-specific",
                   format(READOUT$n_female, big.mark = ","),
                   format(READOUT$n_male, big.mark = ","))),
  ymax = 7.4), "B_cumulative_incidence_by_sex.png")

save_png(curve_panel(
  filter(est, panel == "def"), c("All ASCVD" = S1, "Acute only" = S2),
  "The outcome definition, made visible",
  sub_line(sprintf("same at-risk set · %s events all-classes vs %s acute (%.1f:1)",
                   format(READOUT$n_broad, big.mark = ","),
                   format(READOUT$n_acute, big.mark = ","),
                   READOUT$n_broad / READOUT$n_acute)),
  ymax = 7), "C_broad_vs_acute.png")
