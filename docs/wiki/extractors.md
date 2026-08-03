---
title: Extractors
summary: Which languages are actually supported, what an extractor may emit, and the naming trap in the target layout.
updated: 2026-07-31
---

# Extractors

An extractor reads one file and emits **observations** — literal facts
in the file's own terms. It never touches the store, never reads other
files, and never interprets. "File A imports module B" is in scope;
"A is the auth service" is not. See [[knowledge-graph]] for why that
line is load-bearing.

## What is actually supported

- **Swift** — `CygnusExtractorSwift`, built on swift-syntax. The
  richest extractor: real parsing, not pattern matching.
- **Python** — tree-sitter-python.
- **C** — tree-sitter-c (`.c` and `.h`).
- **Rust** — tree-sitter-rust.

Each extractor claims a file by language hint or extension, so a file
with no hint still routes correctly by suffix.

## The `CygnusExtractorTS` naming trap

Read the target name as historical. `CygnusExtractorTS` today holds
`TreeSitterExtractor` (the shared tree-sitter harness) plus the
Python, C, and Rust extractors. **There is no TypeScript grammar in
the dependency list and no TypeScript extractor** — the "TS" is
tree-sitter, not TypeScript.

Two consequences that have bitten:

- A `.ts` / `.tsx` / `.js` file gets no language hint from the
  provider and no extractor claims it. It appears in the graph as a
  file — its existence is a fact — with nothing declared inside it.
- Searching for "the TS extractor" finds a target that does not do
  what its name says. Adding real TypeScript support means a new
  pinned grammar dependency, and dependencies here need a MISSION.md
  audit recorded in `PROGRESS.md`.

## Build files

`CygnusExtractorBuild` reads Makefiles (`Makefile`, `GNUmakefile`,
`*.mk`) and fastlane Fastfiles, emitting one `core:buildRule`
observation per target and per declared dependency. Resolution turns
those into `core:buildTarget` entities and `core:builds` edges to the
files or sibling targets they name. See [[graph-projections]] for the
Build scene, and the overgrowth argument in [[visualization-ideas]]
for why the build belongs in the graph at all.

Two deliberate limits:

- A dependency that names nothing in the repository — an unexpanded
  variable, a tool on `PATH`, a generated file — produces **no edge**.
  The observation is still recorded, so the evidence is not lost, but
  the graph does not invent a target for it.
- Only *simple* variable assignments are expanded, a bounded number
  of passes deep (nested definitions like `TEST_BIN = $(TARGET)_test`
  resolve; self-referential ones stop rather than spin). A variable
  that never resolves stays verbatim rather than becoming a wrong
  answer.

Targets also carry their **recipe** — the commands they run, in
order, as a `core:buildSteps` property rather than one entity per
command. A step has no identity of its own, and minting thousands of
them would bloat the graph to say what an ordered list already says.
Order is the fact: a recipe is a sequence, and a set of commands would
not tell you what the target does.

### The duplicated parser, and how it ended

`CygnusExtractorBuild.MakefileRules` and the app-side
`MakeFlowBuilder` (`Sources/CygnusKit/MakeFlow.swift`) both parse Make
rules. That duplication was intentional while the two wanted
different things — the extractor wanted coupling, the flow builder
wanted a laid-out chart — and it ended on 2026-08-03: the CI Flow the
app shows is `CIFlow.projected(from:)`, a **projection of the graph**
like every other view, as soon as the repo has a snapshot.

The file parsers are still in the tree for exactly one job: charting
a repo in the window before its first analysis finishes, when there
is no graph to project. `CIFlowProjectionTests` diffs the two
constructions against the real Makefiles this view is used on
(cygnus, otter, sloth) so the fallback cannot silently drift from
the projection. When the pre-analysis window stops mattering, the
parsers go.

### The expansion-versus-spelling decision (settled 2026-08-03)

sloth's Makefile builds `$(TARGET)`, and the two sides disagreed
about what to call it: the graph expanded the variable to `sloth`
(an entity needs an identity a later revision can match), the chart
kept `$(TARGET)` verbatim (decided in 9342eea so variable and
pattern targets stay visible). Of the three ways out — accept the
new labels, record the spelling alongside the expansion, or keep the
parser forever — Jeff chose the middle one:

- The entity's **identity is the expansion** (`sloth`). Unchanged.
- The **spelling rides along** as `core:buildTargetVerbatim` when it
  differs, and the projection labels rows with it — the chart reads
  as the file is written, exactly as before the swap.
- **Pattern rules are facts now.** `%.o` is a `core:buildTarget`
  flagged `core:buildPattern`: a declared shape rather than an
  artifact, but a stable, named, recipe-carrying piece of the build,
  and a row the chart must not lose. `.PHONY` travels the same way
  (`core:buildPhony`), so the entry node can say `make` vs `goal`
  without re-reading the file.

Step labels stay expanded (`cc`, not `$(CC)` — the 9342eea
readability), and both constructions now expand mid-word variables
and reduce an unresolvable `$(MAKE)` to `MAKE`, so the differential
holds on sloth too.

### Fastlane triggers come from workflow evidence (2026-08-03)

Trigger nodes name the CI workflow file that invokes a lane
("deploy.yml"). These were the half of the fastlane chart the graph
could not produce — nothing extracted `.github/workflows`, and in
fact `LocalFSProvider` skipped all hidden directories, so the
workflows never even reached the manifest. Now:

- `.github` is walked (the one hidden directory allowed through —
  CI workflows are build evidence).
- `BuildExtractor` claims `.github/workflows/*.yml` and emits
  `core:ciInvocation` observations: the literal command line a
  workflow runs (`bundle exec fastlane ios beta`).
- Resolution matches the command's tokens against the lanes the
  repository's Fastfiles declare and asserts a `core:invokes` edge
  from the workflow **file** entity to the lane entity — no new
  entity kind; a workflow file was already a file.
- The projection draws the trigger column from those edges, with the
  same ids the file parser used, so the build tracker still matches.

## Adding a language

For a tree-sitter language: a pinned grammar dependency, a query, and
a normalization step that maps captures into cygnus vocabulary. The
grammar packages are pinned to exact versions deliberately — a
grammar bump silently changes node names and quietly changes what the
graph says.

Also update the provider's language-hint table, or the extractor will
only ever be reached by extension fallback.

## Where extraction stops

Extractors give you declarations and imports — the syntax baseline.
They cannot tell you that a call in one file lands on a definition in
another; that requires the compiler. See [[index-enrichment]].
