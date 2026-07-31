# How Cygnus Thinks

Worth five minutes, because it explains what the views are and are
not.

## The graph is the model

Your repository is *evidence*, not the model. Cygnus reads it and
records facts, and the graph of those facts is the only model. Every
visualization — outline, 2D graph, flowchart — is a disposable
projection of that graph. Nothing you see is a second copy of the
truth, and nothing drawn on screen writes back.

## Three layers of knowing

Every fact belongs to exactly one layer:

- **Observed** — read directly from evidence. "This file imports this
  module."
- **Derived** — mechanical aggregation of observed facts. "Files under
  this directory import that module twelve times." Arithmetic, not
  judgment.
- **Inferred** — interpretation, where judgment enters.

Observations stay literal on purpose. "File A imports module B" is an
observation; "A is the auth service" is not, however obvious it looks.

## Facts die with their evidence

Every derived or inferred fact links back to the observations
supporting it. When a file changes and its observations go away,
everything built on them goes too — automatically, because those
links *are* the invalidation index.

## Nothing is overwritten

The store is append-only. Facts carry revision intervals, so a
revision can be queried as of any point and two revisions can be
diffed. Analysis history is a property of the storage, not a log
someone remembered to write.

## Directory structure is not architecture

Cygnus never assumes the folder layout equals the design. That is why
**Role** grouping infers structure from dependency flow with no names
involved, and why it is worth comparing against **Pattern**, which
reads naming conventions. Agreement is evidence; disagreement is
interesting.

## What this means in practice

- An empty **Symbols** view is a missing index build, not a missing
  feature.
- A file with no visible dependencies still appears, because absence
  of an import is not absence of code.
- Re-analysis is cheap and safe. It adds a revision; it never
  rewrites one.
