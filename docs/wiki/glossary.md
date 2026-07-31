---
title: Glossary
summary: One-line definitions for the vocabulary used across the codebase and this wiki.
updated: 2026-07-31
---

# Glossary

**Blast radius** — the neighborhood lit up when you focus a node: its
dependencies and dependents. What changing it could touch.

**Charting rules** — the filters deciding which nodes reach the
screen. The usual explanation for a graph that looks too empty.
See [[graph-projections]].

**Derived layer** — facts computed mechanically from observed facts.
Arithmetic, not judgment.

**Deriver** — a pure pass that reads the graph and returns derived-layer
changes for the caller to commit. Never reads providers.

**Entity** — a node: repository, directory, file, module, type,
interface, enumeration, function, variable.

**Evidence** — the repository itself. Raw input, never authoritative
about meaning.

**Extractor** — reads one file, emits literal observations, touches
nothing else. See [[extractors]].

**Grouping** — how scene nodes cluster spatially: Area, Folder, Layer,
Pattern, Role, None.

**Index store** — the compiler's record of definitions, references,
and calls, keyed by USR. The source of truth for who calls whom.
See [[index-enrichment]].

**Inferred layer** — interpretation. The only layer where judgment is
allowed, and the one held to the highest bar.

**Internal module** — a module whose name matches a directory in the
repo; always charted, unlike third-party externals.

**Knowledge layer** — observed, derived, or inferred. Every fact
belongs to exactly one.

**Observation** — a literal fact read from evidence, in the evidence's
own terms. "File A imports module B", never "A is the auth service".

**Observed layer** — facts read directly from evidence.

**Provenance** — links from a derived or inferred fact to the
observations supporting it. Doubles as the invalidation index: facts
die with their evidence.

**Provider** — exposes observable facts from a repository (the working
tree, git, the `gh` CLI) without interpreting them.

**Relationship** — an edge: containment, declaration, import,
dependency rollup, reference, symbol reference, inheritance,
conformance.

**Revision** — one committed transaction's worth of graph change,
carried as a `[valid_from, valid_to)` interval on every row.
See [[storage]].

**Role grouping** — structural roles inferred from fan-in/fan-out with
no names involved: Core, Hub, Entry, Leaf.

**Scene** — the renderable subset of a snapshot: Code, Callers, or
Symbols.

**Snapshot** — an immutable projection of one repository's current
graph. What renderers and the inspector consume; never live engine
objects.

**Stable key** — an entity's identity across re-analyses.

**System module** — an OS framework or language runtime. Never
charted; nobody learns anything from every file pointing at
Foundation.

**USR** — the compiler's unified symbol resolution string. How the
index store identifies a symbol across files.

**Workspace** — one directory holding one database and its registered
repositories. One per directory, process-wide.
