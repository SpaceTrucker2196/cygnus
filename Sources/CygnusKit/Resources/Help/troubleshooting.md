# Troubleshooting

## The graph looks emptier than the repository

First check whether the project has ever been built. Without a build
there is no index store, so Cygnus has imports to work with but no
compiler-resolved references — the wiring between files is missing
even though every file is present.

Then check what the repository actually imports. An app whose imports
are all Apple frameworks genuinely has few chartable dependencies:
system frameworks are never charted. Turn on **Show External Modules**
to add third-party dependencies.

Every source file that declares something appears whether or not it is
wired, so a file missing entirely is worth reporting.

## Callers or Symbols is empty

Both are built from compiler-resolved symbol references, which only
exist after an index build. Build the project and re-analyze. You do
not need to edit a source file first — Cygnus re-reads the index store
even when nothing in the source changed.

## A TypeScript or JavaScript file appears empty

There is no TypeScript extractor yet. Those files are recorded as
files but nothing is extracted from inside them. Swift, Python, C, and
Rust are supported.

## A repository needs relinking

Its bookmarked folder moved or was deleted. Pick the folder again — a
bookmark to a path that no longer exists cannot be repaired.

## Analysis is slow on a large repository

Analysis is bounded by a hard memory ceiling, shown in the sidebar
meter; large trees are read within that budget rather than all at
once. Reading a large index store is usually the slowest phase, and it
only happens when an index store exists. Analysis is cancellable, and
the next run only re-reads what changed.

## Coverage shows nothing

Coverage is read from a real test run's artifact. Run the suite with
coverage enabled — from the graph, or however you normally run tests —
and the halos appear. Cygnus never estimates coverage.

## The Run button is disabled in CI Flow

Only Makefile flows run from the button. A fastlane lane can sign and
upload, so those are started deliberately from a terminal instead.
