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

test_that("an already-unpacked package folder is found, and preferred over a zip", {
  # The state the user is actually in: ~/AHAprevent/DESCRIPTION, nothing zipped. This used to report
  # "no PREVENT zip found" while a perfectly good package sat next to it.
  home <- file.path(tempdir(), "iap_home"); unlink(home, recursive = TRUE)
  mk_desc(file.path(home, "AHAprevent"), "AHAprevent")
  writeLines("x", file.path(home, "PREVENT-main.zip"))     # a zip is present too

  hits <- .iap_locate(dirs = home)
  expect_true(length(hits) >= 1)
  expect_equal(basename(hits[1]), "AHAprevent")            # the unpacked folder comes first
  expect_true(dir.exists(hits[1]))
})

test_that("a prevent-named folder WITHOUT a DESCRIPTION is not offered as a package", {
  home <- file.path(tempdir(), "iap_home2"); unlink(home, recursive = TRUE)
  dir.create(file.path(home, "prevent_notes"), recursive = TRUE)
  writeLines("just notes", file.path(home, "prevent_notes", "readme.txt"))
  expect_length(.iap_locate(dirs = home), 0)
})

test_that("a .tar.gz is found — it is the canonical R source-package format", {
  # The failure this closes: AHAprevent_1.0.0.tar.gz in the home directory, and the script replying
  # "found neither a PREVENT zip nor an unpacked package". The most standard form of the thing was
  # the one form it could not see.
  home <- file.path(tempdir(), "iap_tgz"); unlink(home, recursive = TRUE)
  dir.create(home, recursive = TRUE)
  writeLines("x", file.path(home, "AHAprevent_1.0.0.tar.gz"))
  hits <- .iap_locate(dirs = home)
  expect_length(hits, 1)
  expect_match(basename(hits[1]), "tar[.]gz$")
})

test_that("a tarball unpacks to a findable package root", {
  b <- file.path(tempdir(), "iap_tar_src"); unlink(b, recursive = TRUE)
  mk_desc(file.path(b, "AHAprevent"), "AHAprevent", "9.9.9")
  dir.create(file.path(b, "AHAprevent", "R"), recursive = TRUE, showWarnings = FALSE)
  writeLines("prevent_base <- function(...) 1", file.path(b, "AHAprevent", "R", "p.R"))

  tp <- file.path(tempdir(), "AHAprevent_9.9.9.tar.gz"); unlink(tp)
  old <- setwd(b); on.exit(setwd(old), add = TRUE)
  made <- tryCatch({ utils::tar(tp, "AHAprevent", compression = "gzip"); file.exists(tp) },
                   error = function(e) FALSE, warning = function(w) file.exists(tp))
  setwd(old)
  skip_if_not(isTRUE(made), "no tar utility on this machine")

  dest <- file.path(tempdir(), "iap_tar_out")
  root <- .iap_unpack(tp, dest = dest)
  expect_false(is.null(root))
  expect_equal(basename(.iap_pkg_root(root)), "AHAprevent")
})

test_that("a prevent-named archive that is not an R package yields no package root", {
  # AHA_prevent_STATA.zip is a real file in a real Downloads folder: it matches the name search and
  # contains no DESCRIPTION. Taking only the FIRST candidate turned it into a hard stop whose error
  # message described the wrong file; the caller now tries the next one instead.
  b <- file.path(tempdir(), "iap_decoy_src"); unlink(b, recursive = TRUE)
  dir.create(file.path(b, "prevent_stata"), recursive = TRUE)
  writeLines("* stata do-file", file.path(b, "prevent_stata", "prevent.do"))

  zp <- file.path(tempdir(), "AHA_prevent_STATA.zip"); unlink(zp)
  old <- setwd(b); on.exit(setwd(old), add = TRUE)
  zipped <- tryCatch({ utils::zip(zp, "prevent_stata", flags = "-qr"); file.exists(zp) },
                     error = function(e) FALSE, warning = function(w) file.exists(zp))
  setwd(old)
  skip_if_not(isTRUE(zipped), "no zip utility on this machine")

  root <- .iap_unpack(zp, dest = file.path(tempdir(), "iap_decoy_out"))
  expect_false(is.null(root))          # it unpacked fine
  expect_null(.iap_pkg_root(root))     # it is simply not an R package
})

test_that("the deep sweep is depth-bounded, and still finds a nested upload", {
  # It used to be recursive = TRUE over the home directory of a Workbench instance, which on a large
  # workspace takes long enough to be indistinguishable from a hang.
  home <- file.path(tempdir(), "iap_depth"); unlink(home, recursive = TRUE)
  dir.create(file.path(home, "uploads"), recursive = TRUE)
  writeLines("x", file.path(home, "uploads", "AHAprevent.zip"))         # one level down: found
  dir.create(file.path(home, "a", "b", "c"), recursive = TRUE)
  writeLines("x", file.path(home, "a", "b", "c", "AHAprevent.zip"))     # three down: not walked

  hits <- .iap_locate(dirs = home)
  expect_length(hits, 1)
  expect_true(grepl("uploads", hits[1], fixed = TRUE))
})
