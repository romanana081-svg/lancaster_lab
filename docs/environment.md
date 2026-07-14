# Development environment

What is actually installed on the development machine, and how to invoke it.

This file exists because **both interpreters are installed but neither is on `PATH`**, which made one
of them look absent for long enough that it was written into `DECISIONS.md` as a project cost and into
`handoff.md` as a blocker. An environment quirk that is not written down gets rediscovered at the cost
of an afternoon.

Verified **2026-07-13** on Windows 11 (`win32`).

---

## What is installed

| Tool | Version | Location | On `PATH`? |
|---|---|---|---|
| Python | 3.13.7 (3.12 also present) | `%LOCALAPPDATA%\Programs\Python\Python313\python.exe` | ❌ no |
| R | 4.6.0 (4.3.2 also present) | `C:\Program Files\R\R-4.6.0\bin\Rscript.exe` | ❌ no |
| `duckdb` (Python) | 1.5.4 | site-packages | — |
| `tidyverse` (R) | present | R 4.6.0 library | — |
| `testthat`, `DBI` (R) | present | R 4.6.0 library | — |
| `duckdb` (R) | 1.5.4.3 — **installed 2026-07-14** | R 4.6.0 library | — |
| `arrow` (R) | 24.0.0 — **installed 2026-07-14** | R 4.6.0 library | — |
| `bigrquery` (R) | **absent** | — | — |

**`duckdb` and `arrow` were installed on 2026-07-14 and both were load-bearing:**
- **`duckdb`** — without it, **R could not read the fixture at all**, so none of the SQL-touching code
  could be tested offline. That is half of this week's goal ("test it here *and* in All of Us").
- **`arrow`** — D-012 keeps the phenotype table as a **Parquet** file. A CSV fallback is explicitly
  rejected: CSV has no types, and the type drift it invites is the thing the contract exists to prevent.

**`bigrquery` is still absent**, and that is fine: it is only needed to talk to BigQuery, which only
happens inside the Workbench (H-004).

**`bigrquery`'s absence does not block anything offline.** It is only needed by the notebook's
"Do once" cells, which talk to BigQuery, and those only run inside the All of Us Workbench (H-004).
The "Format" cells — the cleaning logic that T-005 lifts into `src/phenotype/` — need only `tidyverse`.

---

## Invoking them

The fixture's `README.md` says `py fixture/build/generate.py`. **The `py` launcher is not on `PATH`
either**, so that command fails in a fresh shell. Use a full path, or put the interpreters on `PATH`
for the session.

**PowerShell — one-off:**

```powershell
& "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe" fixture/build/verify.py
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" -e "sessionInfo()"
```

**PowerShell — for the session (preferred):**

```powershell
$env:PATH = "$env:LOCALAPPDATA\Programs\Python\Python313;C:\Program Files\R\R-4.6.0\bin;$env:PATH"
python fixture/build/verify.py
Rscript -e "library(tidyverse)"
```

**Git Bash:**

```bash
export PATH="/c/Users/$USER/AppData/Local/Programs/Python/Python313:/c/Program Files/R/R-4.6.0/bin:$PATH"
python fixture/build/verify.py
```

---

## Rebuilding the fixture

Only `duckdb` is required.

```powershell
$env:PATH = "$env:LOCALAPPDATA\Programs\Python\Python313;$env:PATH"
python fixture/build/generate.py   # DuckDB CDR + answer key   (~4 MB, gitignored, regenerable)
python fixture/build/export.py     # runs the notebook's 13 queries verbatim -> sharded CSVs
python fixture/build/verify.py     # replays the R cleaning logic, diffs against the answer key
```

Expected, and currently true:

```
26 pass, 1 reproduced-bug (expected), 0 unexpected failure(s)
```

`verify.py` exits non-zero on any *unexpected* mismatch, so it works as a CI gate as-is. The
"1 reproduced-bug" is deliberate — see `VALIDATION.md` §2.

---

## Running the notebook against the fixture

The notebook's `read_bq_export_from_workspace_bucket()` shells out to `gsutil ls` / `gsutil cat`.
`fixture/build/gsutil` is an offline shim, so the notebook works **unmodified** — the export
directories mirror the real bucket layout and dates, and the `gs://…` paths hardcoded in the "Format"
cells resolve as-is.

```bash
export PATH="$(pwd)/fixture/build:$PATH"
export FIXTURE_BUCKET_ROOT="$(pwd)/fixture/bucket"
```

Now that R is confirmed present with `tidyverse`, the R cleaning cells can be run **locally** against
this — which is what T-005 needs, and which was believed impossible until 2026-07-13.

---

## What is *not* available locally

- **The All of Us Workbench** — `WORKSPACE_CDR`, `WORKSPACE_BUCKET`, `GOOGLE_PROJECT`, `OWNER_EMAIL`,
  and authenticated `gsutil`. Nothing touches real data without it (H-004). This is by design: see
  DESIGN §8. The fixture exists precisely so that its absence blocks almost nothing.
- **Genomic data**, and any offline substitute for it (H-005, Q-G3). This is a real gap — the entire
  genetic half currently has no way to be tested outside the cloud.
