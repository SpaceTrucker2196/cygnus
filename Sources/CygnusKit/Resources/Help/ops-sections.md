# Dashboard, Workflow, Issues, Docs

These four sections read your repository directly — git, the `gh` CLI,
and the working tree — so they work whether or not the repo has been
analyzed.

## Dashboard

Factory status at a glance: production-order counts, the latest CI
result, recent converge throughput, and token spend.

## Workflow

Two lenses. **Converge** draws the build loop as a stage diagram.
**CI** lists the repository's GitHub Actions workflows with the status
of their latest run.

## Issues

The work queue: a filterable list of GitHub issues with a detail pane
showing the body, labels, and any linked closing commits. Read-only —
Cygnus will not close or edit issues behind your back.

## Docs

Browse and edit the repository's docs. The tree on the left is grouped
by kind: root docs such as MISSION, AGENTS, FACTORY and README; an
`agents/` directory; and the `docs`, `docs/wiki`, and `docs/views`
directories. The right pane edits, previews, or splits.

Pages under `docs/wiki/` are treated as a wiki: `[[page]]` and
`[[page|label]]` links resolve between them, ignoring case and the
difference between spaces, underscores, and hyphens.

Saving writes atomically, and an optional commit stages exactly that
one file — never everything, never a push.

Editing respects the repository's own rules:

- `LEDGER.md` is read-only and opens preview-only.
- `METRICS.md` is append-only; a full-body overwrite is refused.
- New files cannot be created at the repository root.
- Nothing can be written outside the repository.
