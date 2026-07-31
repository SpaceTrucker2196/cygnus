# Getting Started

Cygnus models a software system — not its files — and renders that
model. Everything you see is a projection of one graph.

## Add a repository

Use **+** at the bottom of the sidebar and pick a repository folder.
Cygnus keeps a security-scoped bookmark, so the choice survives
relaunches. If a repo later reports that it needs relinking, the
folder moved or was deleted; pick it again.

Adding a repo does not analyze it. The ops sections work immediately,
because they read git and the working tree rather than the graph.

## Analyze

Open **Code Graph** and press **Run Analysis**. The banner reports
each phase — scanning, extracting, resolving, committing — and the
graph grows on screen while the engine works rather than appearing all
at once. Analysis is cancellable at any point.

Re-analyzing is cheap: only changed files are re-read.

## The six sections

Each repository remembers which section you last used.

- **Dashboard** — factory status at a glance.
- **Workflow** — the converge loop and CI runs.
- **CI Flow** — the build pipeline as a flowchart, runnable.
- **Issues** — the work queue.
- **Docs** — read and edit the repo's docs.
- **Code Graph** — the analyzed graph.

## Get more out of the graph

Build the project first. A build leaves an index store behind, and
Cygnus reads it to learn which call lands on which definition —
turning a graph of imports into a graph of actual wiring, and filling
in the **Callers** and **Symbols** views. Both SPM builds and Xcode
builds work.

Without a build you still get the full structural picture; you just
do not get compiler-resolved references.
