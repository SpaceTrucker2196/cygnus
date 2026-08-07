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
| D9 | 2026-08-06 | XCUITest UI tests replaced by headless CygnusKit coverage | adopted | measured: app presents 0 windows under XCUITest | — |
| D10 | 2026-08-06 | sloth is the reference instance; the audit is validated against it | adopted | CygnusCore/Tests/RetrievalTests/SlothPatternTests.swift | — |
| D11 | 2026-08-07 | Core ML conversion blocked on coremltools 9 / torch 2.7 | provisional | four hypotheses eliminated, see below | — |

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

## D9 — XCUITest removed, adopted

**Decision.** Delete the `CygnusUITests` target and cover what it
asserted from `CygnusKitTests` instead (`BrowseRepoTests`).

**Why.** The UI tests never passed. Measured 2026-08-06: launched by
XCUITest the app process lives ~60 s and consumes CPU while presenting
**zero windows**, confirmed via System Events — an accessibility path
independent of XCUITest's own tree. The same binary launched through
LaunchServices presents a window and seeds correctly.

The earlier diagnosis in PROGRESS.md (2026-07-24) — "XCUITest in this
login session sees an empty AX tree… rerun after reboot" — is
**falsified**. The tree is not empty; it contains the menu bar and
TouchBar. There is genuinely no window, and no reboot will change that.

Also ruled out by experiment: the `--uitest-seed-repo` flag (a plain
launch fails identically) and the `.defaultLaunchBehavior(.presented)`
/ `.restorationBehavior(.disabled)` modifiers (removing both changes
nothing). This matches a known class of macOS regressions where a
SwiftUI `WindowGroup` app launched by the system rather than by a user
never presents its main window.

**What this costs.** Real UI-layer coverage. Nothing in
`BrowseRepoTests` proves a button is clickable; if the shell breaks,
those tests stay green. That trade is stated in the test file rather
than left implicit.

**What would change this.** A macOS or Xcode release where a SwiftUI
app launched by XCUITest presents its window — retest with a throwaway
target before reinstating.

## D11 — Core ML conversion is blocked, provisional

**Status.** The semantic tier is built and tested; no model artifact
exists because conversion fails in the toolchain, not in our code.

**The failure.** Always the same op —
`coremltools/converters/mil/frontend/torch/ops.py:_int` calling `int()`
on a non-0-dimensional array:

    TypeError: only 0-dimensional arrays can be converted to Python scalars

**Eliminated by experiment** (2026-08-07), each a separate run:

| Hypothesis | Test | Result |
|---|---|---|
| jina's ALiBi position bias | converted stock BERT (`BAAI/bge-base-en-v1.5`) instead | identical failure |
| symbolic sequence length | fixed `(1, 256)` shape rather than `EnumeratedShapes` | identical failure |
| SDPA attention graph | `attn_implementation="eager"` | identical failure |
| transformers too new | 5.14.1 → 4.57.6 → 4.44.2 | identical failure |

So it is independent of model, architecture, input shape, attention
implementation, and transformers version. What remains is
**coremltools 9.0's torch frontend against torch 2.7.0**.

**Not yet tried**, in rough order of promise: coremltools 8.x rather
than 9.0; the `torch.export` frontend instead of `torch.jit.trace`;
dropping `config.torchscript = True`; an ONNX intermediate; or a
prebuilt Core ML encoder that skips conversion entirely.

**What this costs.** Nothing already shipped. Every other tier works,
and the degradation contract means the absence is reported rather than
hidden: status says `unavailable`, `mode: hybrid` runs lexical and says
so, `mode: semantic` errors with the fix. The semantic tier turns on
the day a model lands, with no further code.

## D10 — sloth is the pattern's ground truth, adopted

**Decision.** sloth is the first dark factory and the reference
instance of the pattern. When `FactoryAudit` and sloth disagree, **the
audit is wrong**. `SlothPatternTests` pins that, gated behind
`CYGNUS_E2E_SLOTH=1` so the default suite stays hermetic.

**Why it needs saying.** The first version of the audit reported sloth
as not running a dark factory, because sloth keeps its charter under
`agents/` and the audit only knew the template's layout. An agent
trusting that verdict would have "fixed" the reference implementation
into the wrong shape — which is a worse outcome than the audit simply
not existing.

**What would change this.** sloth ceasing to be maintained as the
reference, or the pattern acquiring a spec independent of any
instance.

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
