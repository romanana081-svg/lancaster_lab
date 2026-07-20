# egfr.R — eGFR from serum creatinine, CKD-EPI 2021 (race-free). T-003.
#
# WHY RACE-FREE, AND WHY IT MATTERS: PREVENT (D-004) was deliberately built without race. eGFR is a
# PREVENT input, and the OLDER CKD-EPI equations carried a Black-race coefficient (x1.159). Using one
# of those here would smuggle race back into a model designed without it -- a real scientific error,
# not a nit. This implements the 2021 CKD-EPI CREATININE equation, which removed the race term
# (Inker LA et al., "New Creatinine- and Cystatin C-Based Equations to Estimate GFR without Race",
# N Engl J Med 2021;385:1737-1749). Coefficients are transcribed from that paper.
#
#   eGFR = 142 * min(Scr/kappa, 1)^alpha * max(Scr/kappa, 1)^(-1.200) * 0.9938^age * (1.012 if female)
#     kappa = 0.7 (female) / 0.9 (male);  alpha = -0.241 (female) / -0.302 (male)
#   Scr in mg/dL, age in years, result in mL/min/1.73m^2.

#' eGFR via CKD-EPI 2021 creatinine (race-free). Vectorised.
#'
#' @param scr serum creatinine, mg/dL
#' @param age years
#' @param sex "female" or "male" (matches preventr's coding)
#' @return eGFR in mL/min/1.73m^2 (NA where any input is NA or sex is unrecognised)
egfr_ckd_epi_2021 <- function(scr, age, sex) {
  sex <- tolower(as.character(sex))
  is_f <- sex == "female"
  is_m <- sex == "male"
  kappa <- ifelse(is_f, 0.7, ifelse(is_m, 0.9, NA_real_))
  alpha <- ifelse(is_f, -0.241, ifelse(is_m, -0.302, NA_real_))
  fem   <- ifelse(is_f, 1.012, ifelse(is_m, 1.0, NA_real_))
  ratio <- scr / kappa
  142 * pmin(ratio, 1)^alpha * pmax(ratio, 1)^(-1.200) * 0.9938^age * fem
}
