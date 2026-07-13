# loop.md

**The working loop.** How a session in this repository is meant to run — whether the worker is a human
or an AI agent.

The loop exists because this project has a specific failure mode. It is not "the code crashes". It is
**a plausible number, produced confidently, that is wrong** — and produced *fast*, because the
convenient choice is usually the biased one (the earliest lab value, the visit where all the data
happens to exist, the gene set chosen after glancing at the p-values). The loop is a set of speed bumps
placed exactly where speed is dangerous.

---

## The loop

```
  1. ORIENT      read DESIGN → TASKS → handoff. What is the highest-priority unblocked task?
        │
  2. CHECK       is it really unblocked? does it depend on an OPEN 🔴 question?
        │          ├─ blocked by a human   → handoff.md, then pick another task
        │          └─ blocked by a decision → QUESTIONS.md; decide it, or do the analysis that decides it
        │
  3. STATE       write the "Done when" before writing any code.
        │          if you cannot state it, you do not yet understand the task.
        │
  4. WORK        smallest change that satisfies it. no hard-coded thresholds — they go in configs/.
        │
  5. VALIDATE    run the tests. run the fixture. a task is NOT done until its validation passes.
        │
  6. RECORD      assumption made?  → ASSUMPTIONS.md, and cite the A-id in the code comment
        │          decision made?    → DECISIONS.md  (append-only; never delete an entry)
        │          question raised?  → QUESTIONS.md
        │          human needed?     → handoff.md
        │          surprised?        → JOURNAL.md   ← the surprises are the valuable part
        │
  7. COMMIT      code + the documents it changed, in the same commit
        │
  8. HAND OFF    update TASKS.md so the next session knows where it starts
        └──────► back to 1
```

---

## The rules that actually matter

**1. If you assumed something, write it down.**
Not "if it seemed important" — *if you assumed it*. The wrong answers in an epidemiological pipeline
come from assumptions that nobody wrote down, because an unwritten assumption cannot be attacked by a
reviewer. When a line of code only works because something is true and that something is not
guaranteed, it gets an `A-` entry and the code gets a `# A-0NN` comment pointing at it.

**2. Never fix a hard-coded value in place. Move it to `configs/`.**
Thresholds, concept IDs, gene lists, MAF cut-offs, physiologic bounds: all of them are *scientific
choices*. A choice buried in code is a choice nobody can review, and — worse — a choice nobody can
tell you changed.

**3. Freeze analytic choices before you look at outcomes.**
The gene set (Q-G1), the MAF threshold and mask (Q-G2), the NRI cut-points (Q-S3): each must be
committed to a config file **before** any outcome model is fitted. Deciding after seeing the p-values
is the garden of forking paths, and it invalidates the result no matter how good the number looks. Git
history is what makes "we pre-specified this" a checkable claim rather than an assertion.

**4. Never overwrite an analysis output. Version it.**
`phenotypes_v2.parquet` does not replace `phenotypes_v1.parquet` (D-005). A result from last month must
still be reproducible next month, and it cannot be if its inputs can be rewritten underneath it.

**5. Real data never enters this repository. Ever.**
Not in a CSV, not in a notebook output, not in a figure, not in a commit message. `data/` is gitignored.
Only aggregate, non-identifiable results leave the Workbench (DESIGN §8). Note this rule is **currently
violated in spirit** — the notebook is committed with outputs generated from real data, and nobody has
checked them yet (A-012, T-012).

**6. Do not tidy the notebook's rough edges in passing.**
CLAUDE.md marks them as load-bearing history. The LDL == Trig defect, the `Sys.getenv('WORKSPACE_BUCKET')b`
typo, the cells that depend on state produced further down: **flag them, don't silently fix them.** A
silent fix to cleaning logic is indistinguishable from a silent data bug in the diff.

**7. A negative result is a real result — but only if you earned the right to report one.**
That right is earned by validating the baseline (T-007) and pre-specifying the analysis, *before* the
answer is known. An underpowered null (Q-S4) is not a negative result; it is no result. Know which one
you have (DESIGN §9).

---

## When you are stuck

In order:

1. **Is it blocked on a human?** → `handoff.md`. Then pick a different task; do not idle. And note what
   H-003 says: **bring numbers to the advisor, not just questions.** Quantifying the cost of each option
   is almost always unblocked, even when the choice is not.
2. **Is it blocked on a decision?** → `QUESTIONS.md`. Either make the decision and record it as a `D-`
   entry, or do the specific analysis that would settle it. "We'll decide later" is only acceptable if
   the deadline in the question has not passed — and for anything touching outcomes, that deadline is
   *before you look at them*.
3. **Is it blocked because you do not understand it yet?** → the task's "Done when" is missing or vague.
   Go write it. That is usually the actual work.

---

## What a good session leaves behind

Not "code that works". A session leaves:

- a task whose **validation passes**, not one whose code merely runs;
- every assumption it made, **written down**;
- every surprise it hit, in `JOURNAL.md` — including the dead ends, because a dead end that is not
  recorded gets explored a second time;
- `TASKS.md` updated, so the next session starts oriented rather than archaeological.

The measure of a session is not how much was produced. It is whether **someone else — or you, in six
months — could pick it up cold and know exactly where they are, what is true, and what is merely
assumed.**
