# install_ahaprevent.R — install the AHA PREVENT package from a zip you uploaded, and PROVE it works.
#
# RUN IT (in the Workbench, R console):
#   setwd("~/lancaster_lab")
#   source("src/workbench/install_ahaprevent.R")
#   install_ahaprevent()
#
# It searches for the zip, unpacks it, finds the package root, installs it, and then scores the
# published worked example from the paper. Pass a path if the search does not find it:
#   install_ahaprevent("~/PREVENT-main.zip")      # a zip
#   install_ahaprevent("~/PREVENT-main")          # an already-unzipped folder
#   install_ahaprevent("gs://your-bucket/PREVENT.zip")   # straight out of the workspace bucket
#
# ------------------------------------------------------------------------------------------------
# WHY THIS IS A SCRIPT AND NOT THREE LINES IN A RUNBOOK
#
# Three separate things go wrong here and they produce the same symptom -- run_prevent() saying it
# cannot find prevent_base():
#
#   1. HAVING THE CODE IS NOT HAVING THE PACKAGE. requireNamespace() only sees what is on
#      .libPaths(). An unzipped folder in the home directory is invisible to it, and the old advice
#      ("install it from the AHA repo") reads as nonsense to someone who already downloaded it.
#   2. THE ZIP IS NOT THE PACKAGE. A GitHub download unpacks to PREVENT-main/, and DESCRIPTION may be
#      at its root or one level down. install.packages() wants the directory CONTAINING DESCRIPTION;
#      point it at the wrong level and it fails with a message about the wrong thing entirely.
#   3. THE DEFAULT LIBRARY MAY NOT BE WRITABLE. The fix is a user library, which R will not create
#      for you at the moment you need it.
#
# ------------------------------------------------------------------------------------------------
# AND WHY IT VERIFIES RATHER THAN REPORTING SUCCESS
#
# "Installed" is not the claim that matters; "computes the published numbers" is. So the last step
# scores Khan et al.'s own worked example -- a 50-year-old woman, treated SBP 160, TC 240, HDL 55,
# BMI 35, eGFR 90 -- and checks it returns 5.4 / 3.6 / 2.5 percent for 10-year CVD / ASCVD / HF, and
# 9.3 / 6.0 / 4.7 for the smoker variant. If those match, the equation, this project's adapter, and
# the sex and logical coding in between are all correct, and the whole validation rests on something
# checked rather than assumed. If they do not match, you have found that out in ten seconds rather
# than after a full cohort run.
#
# Source: Khan SS et al., Circulation 2024;149:430-449, doi:10.1161/CIRCULATIONAHA.123.067626
# (open access at PMC10910659). The same example is the basis of tests/testthat/
# test-prevent-published-example.R, so this check and the test suite cannot drift apart silently.
# ------------------------------------------------------------------------------------------------

`%||%` <- function(a, b) if (is.null(a) || !length(a)) b else a

#' Print progress on STDOUT, flushed immediately.
#'
#' Deliberately not message(). message() writes to stderr, and a Jupyter R kernel frequently does not
#' surface stderr in the cell output at all -- so a function that reports its progress entirely
#' through message() produces LITERALLY NOTHING in a notebook, and an install that is working
#' perfectly is indistinguishable from one that has hung. That is the single most confusing failure
#' mode this script can have, because the user's only reasonable conclusion is that it is broken.
#'
#' flush.console() matters for the same reason: without it R buffers, and the output arrives in one
#' lump at the end, which is exactly when it stops being progress.
.iap_say <- function(...) {
  cat(..., "\n", sep = "")
  utils::flush.console()
  invisible(NULL)
}

#' Where a zip plausibly lands in a Workbench instance, in the order worth looking.
.iap_search_dirs <- function() {
  unique(Filter(dir.exists, c(
    getwd(), path.expand("~"), path.expand("~/lancaster_lab"),
    "/home/jupyter", "/home/jupyter/workspaces",
    path.expand("~/Downloads"))))
}

#' Find a PREVENT zip, or an ALREADY-UNPACKED package directory.
#'
#' Both are normal states to arrive in: some people upload the zip, some unzip it first, and the
#' second group was previously told "no PREVENT zip found" while a perfectly good package sat in the
#' home directory. An unpacked directory is preferred when both exist -- it is the one the user
#' already looked at, and re-unzipping over it would discard any edit they made.
.iap_locate <- function(dirs = .iap_search_dirs()) {
  # 1. unpacked package directories: a prevent-ish folder name with a DESCRIPTION in it.
  unpacked <- character(0)
  for (d in dirs) {
    sub <- tryCatch(list.dirs(d, recursive = FALSE, full.names = TRUE),
                    error = function(e) character(0))
    sub <- sub[grepl("prevent", basename(sub), ignore.case = TRUE)]
    for (s in sub) if (!is.null(.iap_pkg_root(s))) unpacked <- c(unpacked, s)
  }

  # 2. zips, top level first, then one sweep deeper -- the file browser often nests an upload.
  zips <- character(0)
  for (d in dirs)
    zips <- c(zips, list.files(d, pattern = "prevent.*\\.zip$", ignore.case = TRUE,
                               full.names = TRUE, recursive = FALSE))
  for (d in dirs)
    zips <- c(zips, head(tryCatch(list.files(d, pattern = "prevent.*\\.zip$", ignore.case = TRUE,
                                             full.names = TRUE, recursive = TRUE),
                                  error = function(e) character(0)), 20))

  unique(c(unpacked, zips))
}

#' Pull a gs:// object down to a local temp file. Returns the local path.
.iap_from_bucket <- function(gs_path) {
  dest <- file.path(tempdir(), basename(gs_path))
  .iap_say("  fetching ", gs_path)
  st <- suppressWarnings(system2("gsutil", c("cp", shQuote(gs_path), shQuote(dest)),
                                 stdout = TRUE, stderr = TRUE))
  if (!file.exists(dest))
    stop(sprintf("could not copy %s out of the bucket. gsutil said:\n  %s",
                 gs_path, paste(st, collapse = "\n  ")), call. = FALSE)
  dest
}

#' Find the directory holding DESCRIPTION -- i.e. the actual R package root.
#'
#' Prefers a DESCRIPTION whose Package: field looks like PREVENT, then the shallowest one. A repo can
#' contain several (vignettes, a bundled dependency), and picking the wrong one installs the wrong
#' thing with no error at all.
.iap_pkg_root <- function(root) {
  desc <- list.files(root, pattern = "^DESCRIPTION$", recursive = TRUE, full.names = TRUE)
  if (!length(desc)) return(NULL)
  score <- vapply(desc, function(p) {
    nm <- tryCatch(read.dcf(p, fields = "Package")[1, 1], error = function(e) NA_character_)
    depth <- length(strsplit(p, "[/\\\\]")[[1]])
    # lower is better: a prevent-ish Package name wins outright, then shallower paths
    (if (!is.na(nm) && grepl("prevent", nm, ignore.case = TRUE)) 0 else 100) + depth
  }, numeric(1))
  dirname(desc[which.min(score)])
}

#' Score the paper's worked example and check it against the published values.
#'
#' @return list(ok, detail) — ok is TRUE only if every value matches within the paper's own rounding.
verify_ahaprevent <- function(quiet = FALSE) {
  if (!file.exists("src/ascvd/prevent/run_prevent.R"))
    return(list(ok = NA, detail = "not at the repo root — cannot check the adapter; setwd(\"~/lancaster_lab\")"))
  source("src/ascvd/prevent/run_prevent.R", local = TRUE)

  panel <- data.frame(
    person_id = c(1L, 2L), age = 50, sex = "female", sbp = 160, bp_tx = TRUE,
    total_c = 240, hdl_c = 55, statin = FALSE, dm = FALSE,
    smoking = c(FALSE, TRUE), egfr = 90, bmi = 35, stringsAsFactors = FALSE)

  s <- tryCatch(suppressMessages(run_prevent(panel)),
                error = function(e) { list(err = conditionMessage(e)) })
  if (!is.null(s$err)) return(list(ok = FALSE, detail = paste("run_prevent() errored:", s$err)))

  # Paper reports 10-year risks to 0.1pp, so 0.05pp is the rounding floor, not an arbitrary epsilon.
  want <- data.frame(
    what  = c("10yr CVD", "10yr ASCVD", "10yr HF", "10yr CVD (smoker)",
              "10yr ASCVD (smoker)", "10yr HF (smoker)"),
    got   = c(s$prevent_base_10yr_CVD[1], s$prevent_base_10yr_ASCVD[1], s$prevent_base_10yr_HF[1],
              s$prevent_base_10yr_CVD[2], s$prevent_base_10yr_ASCVD[2], s$prevent_base_10yr_HF[2]),
    paper = c(5.4, 3.6, 2.5, 9.3, 6.0, 4.7), stringsAsFactors = FALSE)
  want$diff <- want$got - want$paper
  want$pass <- is.finite(want$got) & abs(want$diff) <= 0.05

  if (!quiet) {
    .iap_say("\n  published worked example (Khan et al. 2024, Circulation):")
    for (i in seq_len(nrow(want)))
      .iap_say(sprintf("    %-22s ours %6s   paper %4.1f   %s", want$what[i],
                      if (is.finite(want$got[i])) sprintf("%.2f", want$got[i]) else "NA",
                      want$paper[i], if (want$pass[i]) "OK" else "MISMATCH"))
  }
  list(ok = all(want$pass), detail = want)
}

#' Install AHAprevent from an uploaded zip (or folder, or bucket object) and verify it.
#'
#' @param src  path to a .zip, an unpacked folder, or a gs:// object. NULL searches for one.
#' @param lib  library to install into. NULL tries the default, then falls back to R_LIBS_USER.
#' @param force reinstall even if AHAprevent is already present.
#' @return invisibly, the verification result.
install_ahaprevent <- function(src = NULL, lib = NULL, force = FALSE) {
  # Say something IMMEDIATELY. Everything below can take a while, and silence is the one output that
  # tells the user nothing about whether it is working.
  .iap_say("install_ahaprevent(): starting")
  .iap_say("  wd        : ", getwd())
  .iap_say("  libPaths  : ", paste(.libPaths(), collapse = " | "))

  have <- requireNamespace("AHAprevent", quietly = TRUE)
  if (have && !force) {
    .iap_say("AHAprevent is ALREADY installed (version ",
            as.character(utils::packageVersion("AHAprevent")), ").")
    .iap_say("Checking it against the published example rather than taking that at face value...")
    v <- verify_ahaprevent()
    .iap_say(if (isTRUE(v$ok)) "\n  PASS — the installed package reproduces the paper. Nothing to do."
            else "\n  It did NOT reproduce the paper. Re-install with: install_ahaprevent(force = TRUE)")
    return(invisible(v))
  }

  # -- 1. find the source ---------------------------------------------------------------------
  if (is.null(src)) {
    .iap_say("  searching for a PREVENT package or zip in:")
    for (d in .iap_search_dirs()) .iap_say("    ", d)
    cand <- .iap_locate()
    .iap_say("  found ", length(cand), " candidate(s)")
    if (!length(cand))
      stop("install_ahaprevent(): found neither a PREVENT zip nor an unpacked package. Looked in:\n  ",
           paste(.iap_search_dirs(), collapse = "\n  "),
           "\n\n  Pass the path directly. To see where your upload landed:",
           "\n    list.files(\"~\", pattern = \"zip$\", recursive = TRUE)[1:20]",
           "\n  Or, if you uploaded it to the workspace bucket:",
           "\n    system(paste0(\"gsutil ls \", Sys.getenv(\"WORKSPACE_BUCKET\"), \"/**\"))",
           "\n    install_ahaprevent(\"gs://.../PREVENT.zip\")", call. = FALSE)
    src <- cand[1]
    if (length(cand) > 1)
      .iap_say("found ", length(cand), " candidates; using the first:\n  ",
              paste(cand, collapse = "\n  "))
  }
  if (grepl("^gs://", src)) src <- .iap_from_bucket(src)
  src <- path.expand(src)
  if (!file.exists(src)) stop("install_ahaprevent(): no such path: ", src, call. = FALSE)

  # -- 2. unpack ------------------------------------------------------------------------------
  if (grepl("\\.zip$", src, ignore.case = TRUE)) {
    dest <- file.path(path.expand("~"), "ahaprevent_src")
    unlink(dest, recursive = TRUE); dir.create(dest, recursive = TRUE, showWarnings = FALSE)
    .iap_say("unzipping ", src, "\n  -> ", dest)
    utils::unzip(src, exdir = dest)
    root <- dest
  } else {
    root <- src
  }

  # -- 3. find the package root ---------------------------------------------------------------
  pkg <- .iap_pkg_root(root)
  if (is.null(pkg)) {
    top <- head(list.files(root, recursive = TRUE), 30)
    stop(sprintf("install_ahaprevent(): no DESCRIPTION anywhere under %s, so this is loose source
  files rather than an R package. That is still usable — find the file defining prevent_base() and
  source it; run_prevent() picks up a sourced copy and reports that it did:

    f <- list.files(\"%s\", pattern = \"[.][Rr]$\", recursive = TRUE, full.names = TRUE)
    f[grepl(\"prevent\", f, ignore.case = TRUE)]
    source(<the file that defines prevent_base>)

  What is in there:\n    %s", root, root, paste(top, collapse = "\n    ")), call. = FALSE)
  }
  .iap_say("package root: ", pkg)

  # -- 4. install, with a user-library fallback ------------------------------------------------
  do_install <- function(target_lib) {
    utils::install.packages(pkg, repos = NULL, type = "source",
                            lib = target_lib %||% .libPaths()[1])
  }
  ok <- tryCatch({ do_install(lib); requireNamespace("AHAprevent", quietly = TRUE) },
                 error = function(e) { .iap_say("  first attempt failed: ", conditionMessage(e)); FALSE },
                 warning = function(w) { .iap_say("  ", conditionMessage(w))
                                         requireNamespace("AHAprevent", quietly = TRUE) })

  if (!ok) {
    ulib <- Sys.getenv("R_LIBS_USER")
    if (nzchar(ulib)) {
      dir.create(ulib, recursive = TRUE, showWarnings = FALSE)
      .libPaths(c(ulib, .libPaths()))
      .iap_say("retrying into your personal library: ", ulib)
      ok <- tryCatch({ do_install(ulib); requireNamespace("AHAprevent", quietly = TRUE) },
                     error = function(e) { .iap_say("  ", conditionMessage(e)); FALSE })
    }
  }
  if (!ok)
    stop("install_ahaprevent(): the package did not install. The messages above name the cause;
  a compile error usually means a missing system library, and a permission error means the fallback
  library path is also not writable.", call. = FALSE)

  .iap_say("\ninstalled AHAprevent ", as.character(utils::packageVersion("AHAprevent")))

  # -- 5. prove it ----------------------------------------------------------------------------
  v <- verify_ahaprevent()
  if (isTRUE(v$ok)) {
    .iap_say("\n  PASS — reproduces the published worked example to the paper's own precision.")
    .iap_say("  You are clear to run:  source(\"src/workbench/01_check.R\"); run_check()")
  } else if (is.na(v$ok)) {
    .iap_say("\n  Installed, but not verified: ", v$detail)
  } else {
    .iap_say("\n  INSTALLED BUT IT DOES NOT REPRODUCE THE PAPER. Do not run the validation on this.")
    .iap_say("  Most likely this zip is not the AHA implementation, or it is a modified copy.")
  }
  invisible(v)
}
