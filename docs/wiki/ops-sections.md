---
title: Ops Sections
summary: Dashboard, Workflow, CI Flow, Issues, Docs, Code Graph — the per-repo panes and where each one gets its data.
updated: 2026-07-31
---

# Ops Sections

A selected repository shows one of six sections, remembered per repo.
Five read the **provider layer** (git, the `gh` CLI, the working
tree); only Code Graph consumes analysis state. That separation is why
the ops sections work on a repo you have never analyzed.

- **Dashboard** — at-a-glance factory status: production-order counts,
  latest CI result, recent converge throughput, token spend.
- **Workflow** — the converge loop as a stage diagram, plus GitHub
  Actions workflows with their latest run status.
- **CI Flow** — the build pipeline as a flowchart, from fastlane
  Fastfiles or Makefiles, runnable for make goals. See [[renderers]].
- **Issues** — the production-order work queue: filterable GitHub
  issues with body, labels, and linked closing commits. Read-only.
- **Docs** — browse and edit the repo's agent docs. Tree grouped by
  kind on the left, edit/preview/split editor on the right.
- **Code Graph** — the analyzed graph, in Outline or Flat.

## Docs, and this wiki

The Docs section is how a wiki gets read. Recognized locations are the
root docs (`MISSION.md`, `AGENTS.md`, `CLAUDE.md`, `FACTORY.md`,
`README.md`, `PROGRESS.md`, `ROADMAP.md`, and friends), `agents/`, and
the doc directories `docs`, `docs/wiki`, `docs/views`. Anything under
`docs/wiki/` is classified as wiki content, and double-bracket links between
pages resolve — case-insensitively, and insensitive to
spaces/underscores/hyphens.

That is why this knowledge base lives at `docs/wiki/`: it is readable
inside Cygnus with no new machinery.

Editing enforces the repo's invariants rather than trusting the UI:

- `LEDGER.md` is read-only — preview only, no save path.
- `METRICS.md` is append-only; a full-body overwrite is refused.
- No *new* files at the repo root.
- No writes escaping the repo.
- A commit stages exactly the one named file. Never `git add -A`,
  never a push.

## Provider layer

Factory data comes from real tooling, not fixtures: the user's `git`
and `gh` binaries, located rather than assumed. The app is
deliberately **not sandboxed** — the ops sections shell out and read
repo files directly, which App Sandbox would block. The cost of that
choice is that App Store distribution is foreclosed, which is
acceptable for an internal developer-ops tool.

Security-scoped access to a repo folder always goes through
`RepoAccessManager.withRepoAccess { }`. Never start or stop the access
by hand — an unbalanced call leaks the resource and the next analysis
fails in a way that looks like a permissions bug.
