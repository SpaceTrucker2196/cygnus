---
title: Cygnus Knowledge Base
summary: Entry point for project knowledge — how the engine thinks, what the app shows, and why each decision was made.
updated: 2026-07-31
---

# Cygnus Knowledge Base

Project knowledge that isn't obvious from the code: the reasoning
behind the model, the shape of the pipeline, and the traps we already
walked into. Read [[knowledge-graph]] first — everything else assumes
its vocabulary.

This wiki is browsable inside Cygnus itself: select the cygnus repo,
open **Docs**, and the `docs/wiki` section lists these pages with
their wiki links resolved.

## What lives where

Documents outside this wiki own their subjects; this wiki links to
them rather than restating them.

- `MISSION.md` — the charter and the sacred invariants.
- `AGENTS.md` / `CLAUDE.md` — rules for coding agents working here.
- `FACTORY.md` — build and infrastructure runbook.
- `docs/architecture.md` — the plan of record.
- `docs/milestones.md` — the roadmap.
- `docs/schema.md` — the storage schema.
- `docs/views/*.md` — per-view UI specs.

## The model

- [[knowledge-graph]] — entities, relationships, properties, the
  three knowledge layers, revisions, and provenance.
- [[storage]] — how the append-only store keeps history without
  mutation.
- [[glossary]] — one-line definitions for the vocabulary.

## Getting facts into the graph

- [[analysis-pipeline]] — snapshot → extract → resolve → derive →
  enrich → commit, and what each phase may and may not do.
- [[extractors]] — the per-language extractors and what each emits.
- [[index-enrichment]] — compiler-resolved references from a built
  index store, including where the store hides for Xcode projects.

## Getting facts onto the screen

- [[graph-projections]] — scenes, and the charting rules that decide
  which nodes you actually see.
- [[renderers]] — the 2D Canvas graph and the Metal CI-flow
  flowchart.
- [[visualization-ideas]] — views worth building, drawn from *Kill It
  With Fire*, and the critique it levels at whole-system graphs.
- [[ops-sections]] — Dashboard, Workflow, CI Flow, Issues, Docs.

## Operating it

- [[cli]] — the `cygnus` command-line harness.
- [[troubleshooting]] — symptoms we have actually diagnosed, with
  the cause and the fix.
