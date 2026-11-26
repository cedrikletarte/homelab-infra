# Architecture decision records

One file per decision: `NNNN-short-title.md`, numbered in order, never renumbered.

## Format

```markdown
# The decision, stated as a sentence

- **Date:** 2026-10-10
- **Status:** Accepted

Context, the decision and why, the alternatives that were rejected.
```

- **Date** is the day the decision was recorded. It never changes.
- **Status** is `Accepted`, or `Superseded by NNNN` once a later decision replaces this one.

## An accepted ADR is never edited

To change a decision, write a new ADR that states the whole new decision and starts its text with `Supersedes NNNN.`, then change the old ADR's status line to `Superseded by NNNN`. That status line is the only edit an accepted ADR ever gets: its text stays as it was, so the history of why things changed stays readable.

A new decision that only adds to an older one (an exception, a new case) does not supersede it: it is a new ADR that refers to the older one, and both stay `Accepted`.

## Index

| ADR | Decision | Status |
|---|---|---|
