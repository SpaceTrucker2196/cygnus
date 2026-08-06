# cygnus — decisions and refusals

Append-only. One row per decision that would otherwise be re-argued
from scratch, and a section below carrying the reasoning.

**A refusal is a decision.** "We measured this and it does not work" is
the single most expensive thing to rediscover and the easiest to lose —
it leaves no code behind, so nothing in the repository reminds anyone
it happened.

## Index

| id | date | decision | status | evidence | supersedes |
|----|------|----------|--------|----------|------------|
| D1 | 2026-07-31 | Forgotten/dead-code detection from the reference graph | refused | docs/wiki/visualization-ideas.md; measured on cygnus | — |
| D2 | 2026-07-19 | SQLite via GRDB, interval-versioned, one DB per workspace | adopted | docs/schema.md E0 benchmark | — |
| D3 | 2026-07-19 | SwiftSyntax over SourceKit-LSP for the Swift extractor | adopted | docs/architecture.md | — |
| D4 | 2026-08-05 | Serialized DatabaseQueue, never DatabasePool, on disk | adopted | PROGRESS.md 2026-07-24; issue #2 | — |
| D5 | 2026-08-05 | Lexical retrieval as FTS5 over CAS blobs, not ripgrep | adopted | docs/wiki/retrieval.md | — |
| D6 | 2026-08-05 | No ANN index (sqlite-vec/HNSW) for vector search | refused | corpus sized at ~13k chunks; ~1-3 ms brute force | — |
| D7 | 2026-08-06 | Hand-rolled MCP protocol rather than the official Swift SDK | adopted | CygnusMCP/JSONRPC.swift | — |
| D8 | 2026-08-06 | Separate cygnus-mcp executable, not a `cygnus mcp` subcommand | adopted | stdout is the protocol | — |

## D1 — dead-code detection, refused

**Refused.** A "forgotten code" lens over the reference graph:
declarations with no inbound references, surfaced as probably-dead.

**Why it fails.** Measured on cygnus itself, a majority of results were
false positives. Index-store coverage does not span the app and package
targets, so a declaration used only from an unindexed target looks
exactly like a dead one. The lens cannot distinguish "nothing
references this" from "nothing I can see references this" — the same
distinction `callers_of` now makes explicit.

**What would change this.** Index coverage spanning every target, or a
confidence signal derived from which targets were indexed.

## D6 — no ANN index, refused

**Refused.** sqlite-vec, HNSW, or any approximate-nearest-neighbour
index for the semantic tier.

**Why it fails the cost/benefit.** The whole factory corpus is ~13k
chunks; budget 50k for growth. At 384 dimensions that is 77 MB
resident and a single `cblas_sgemv` pass — roughly 1–3 ms, memory
bound. An ANN index would add a C dependency requiring a MISSION.md
audit, a tombstone-decay failure mode under continuous re-indexing,
and an approximation to exact recall, to save milliseconds already
inside budget.

**What would change this.** ~500k chunks, i.e. a 10× corpus.

## D7 — hand-rolled MCP, adopted

**Decision.** Implement JSON-RPC over stdio directly rather than adopt
`modelcontextprotocol/swift-sdk`.

**Why.** The needed surface is `initialize`, `notifications/initialized`,
`tools/list`, `tools/call`, `ping` — about 300 lines. The SDK pulls
swift-log, swift-system and swift-collections transitively. In a
package that pins tree-sitter grammars by exact revision because of ABI
churn, three transitive dependencies to avoid 300 lines is the wrong
trade.

**What would change this.** The protocol growing a surface that is
genuinely expensive to track by hand — sampling, or bidirectional
requests.
