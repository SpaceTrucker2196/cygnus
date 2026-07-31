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
