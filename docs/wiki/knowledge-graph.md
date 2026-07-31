---
title: The Knowledge Graph
summary: Entities, relationships, typed properties, three knowledge layers, immutable revisions, and the provenance that ties derived facts to their evidence.
updated: 2026-07-31
---

# The Knowledge Graph

Cygnus models a software *system*, not its files. A repository is raw
evidence; the graph is what we claim to know about it, and every
claim carries its receipt.

## Nodes and edges

Entities are identified by a **stable key** — a string that survives
re-analysis, so the same file keeps the same identity across
revisions. Kinds are namespaced (`core:file`), leaving room for
language-specific kinds (`swift:type`) without collision.

Core entity kinds: `core:repository`, `core:directory`, `core:file`,
`core:module`, `core:type`, `core:interface`, `core:enumeration`,
`core:function`, `core:variable`.

Core relationship kinds:

- `core:containsPhysical` — directory/file containment. Structure of
  the tree, nothing more.
- `core:declares` — a file (or type) declares a declaration.
- `core:imports` — a file imports a module.
- `core:dependsOn` — a directory-level rollup of imports. Derived.
- `core:references` — file → file, compiler-resolved. See
  [[index-enrichment]].
- `core:refersToSymbol` — declaration → declaration, compiler-resolved.
- `core:inherits`, `core:conformsTo` — declared type relationships.
- `core:builds` — build target → what it needs. See [[extractors]].
- `core:authoredBy` — file → person, with a commit count. Derived.
- `core:ownedBy` — file → person. **Inferred**, and the clearest
  example of why the layers exist: git says who committed (observed),
  counting is arithmetic (derived), and "this person owns it" is a
  judgement about concentration that could be wrong.

Properties are typed values attached to entities and relationships
(for example the reference count that sets edge thickness in
[[renderers]]).

## The three layers

Every fact belongs to exactly one `KnowledgeLayer`:

- **observed** — read directly from evidence. "This file contains the
  token `import Foundation` at line 3."
- **derived** — mechanical aggregation of observed facts. Arithmetic,
  not judgment. Directory import rollups are the canonical example:
  "files under `Sources/Kit` import GRDB 12 times."
- **inferred** — interpretation, where judgment enters. Held to a
  higher bar precisely because it can be wrong.

The layer boundary is a design constraint, not a label. An extractor
that emits "this is the auth service" has crossed it — that is not an
observation, and no amount of confidence makes it one. See
[[extractors]].

## Observations are literal

An observation records what the evidence says, in the evidence's own
terms. "File A imports module B" is an observation. "A is the
persistence layer" is not. This is what keeps the graph re-derivable:
if interpretation lives only in the derived and inferred layers, it
can be recomputed — or discarded — without re-reading the repository.

## Revisions and provenance

Rows are **append-only**. Nothing is mutated except to close a
revision interval (`valid_to`), and one revision commit is one
transaction. History is therefore intact by construction: any past
revision can be queried, and two revisions can be diffed.

Every derived or inferred fact links to the observations that support
it. That provenance table doubles as the **invalidation index** — when
an observation disappears because the file changed, everything
standing on it dies with it. Nothing has to remember to clean up.

The practical consequence: derivers never write observations, and
extractors never write derived facts. The layer that owns a fact owns
its lifetime.

See [[storage]] for how this is laid out on disk, and
[[analysis-pipeline]] for when each layer is written.
