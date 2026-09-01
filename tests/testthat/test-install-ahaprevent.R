# Tests for install_ahaprevent.R — the zip-to-installed-package path.
#
# The install itself cannot be tested here without clobbering a real AHAprevent, so what is covered is
# the part that actually goes wrong: finding the package root inside whatever shape the download took.

source(file.path("..", "..", "src", "workbench", "install_ahaprevent.R"))

mk_desc <- function(dir, pkg, version = "1.0.0") {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  writeLines(c(paste("Package:", pkg), paste("Version:", version)), file.path(dir, "DESCRIPTION"))
}

test_that("the package root is found inside a GitHub-style zip layout", {
  root <- file.path(tempdir(), "iap1"); unlink(root, recursive = TRUE)
  mk_desc(file.path(root, "PREVENT-main"), "AHAprevent")
  dir.create(file.path(root, "PREVENT-main", "R"), recursive = TRUE, showWarnings = FALSE)
  expect_equal(basename(.iap_pkg_root(root)), "PREVENT-main")
})

test_that("a nested vendored DESCRIPTION does not win over the real package", {
  # install.packages() pointed at a bundled dependency installs the wrong thing, with no error.
  root <- file.path(tempdir(), "iap2"); unlink(root, recursive = TRUE)
  mk_desc(file.path(root, "PREVENT-main"), "AHAprevent")
  mk_desc(file.path(root, "PREVENT-main", "vendor", "somedep"), "somedep")
  expect_equal(basename(.iap_pkg_root(root)), "PREVENT-main")
})

test_that("the PREVENT package wins over a same-depth decoy that sorts first", {
  # Depth alone would tie here, and alphabetical order would pick the wrong one.
  root <- file.path(tempdir(), "iap3"); unlink(root, recursive = TRUE)
  mk_desc(file.path(root, "aaa_dep"),     "aaa_dep")
  mk_desc(file.path(root, "zzz_prevent"), "AHAprevent")
  expect_equal(basename(.iap_pkg_root(root)), "zzz_prevent")
})

test_that("loose source files with no DESCRIPTION return NULL rather than a wrong guess", {
  root <- file.path(tempdir(), "iap4"); unlink(root, recursive = TRUE)
  dir.create(file.path(root, "code"), recursive = TRUE)
  writeLines("prevent_base <- function(...) 1", file.path(root, "code", "prevent.R"))
  expect_null(.iap_pkg_root(root))
})

test_that("a real zip round-trips: unzip then locate", {
  b <- file.path(tempdir(), "iap5"); unlink(b, recursive = TRUE)
  mk_desc(file.path(b, "PREVENT-main"), "AHAprevent", "9.9.9")
  dir.create(file.path(b, "PREVENT-main", "R"), recursive = TRUE, showWarnings = FALSE)
  writeLines("prevent_base <- function(...) 1", file.path(b, "PREVENT-main", "R", "p.R"))

  zp <- file.path(tempdir(), "iap5.zip"); unlink(zp)
  old <- setwd(b); on.exit(setwd(old), add = TRUE)
  zipped <- tryCatch({ utils::zip(zp, "PREVENT-main", flags = "-qr"); file.exists(zp) },
                     error = function(e) FALSE, warning = function(w) file.exists(zp))
  setwd(old)
  skip_if_not(isTRUE(zipped), "no zip utility on this machine")

  dest <- file.path(tempdir(), "iap5out"); unlink(dest, recursive = TRUE)
  dir.create(dest, recursive = TRUE)
  utils::unzip(zp, exdir = dest)
  pk <- .iap_pkg_root(dest)
  expect_equal(basename(pk), "PREVENT-main")
  expect_equal(unname(read.dcf(file.path(pk, "DESCRIPTION"), fields = "Package")[1, 1]), "AHAprevent")
})

test_that("verify_ahaprevent reproduces the published worked example", {
  # The whole point of the script: installed is not the claim, "computes the paper's numbers" is.
  skip_if_not_installed("AHAprevent")
  old <- setwd(file.path("..", "..")); on.exit(setwd(old), add = TRUE)
  v <- verify_ahaprevent(quiet = TRUE)
  expect_true(isTRUE(v$ok))
  expect_true(all(v$detail$pass))
})
