# Spike: IndexStoreDB for reference resolution (E6)

*2026-07-24. Paper spike — no dependency added; adding one is gated
on a MISSION.md audit.*

## Question

Can IndexStoreDB give cygnus real reference/call edges (who calls
whom, definition↔reference) beyond swift-syntax's syntax-level facts?

## Findings

- **Package**: `github.com/swiftlang/indexstore-db` — Apache-2.0,
  actively maintained (part of the Swift toolchain train), SPM
  package with a C++ core. **No semantic versions**: tags are
  `swift-X.Y-RELEASE` style; SourceKit-LSP pins `branch: main`. We
  would pin an exact `swift-6.x-RELEASE` tag matching the installed
  toolchain — pinnable, but not by semver.
- **Requires compilation.** It reads a raw index store produced by
  the compiler (`-index-store-path`; `swift build` emits one by
  default, Xcode puts it in DerivedData `Index.noindex/DataStore`).
  No build → no store. SourceKit-LSP's
  `swift build --experimental-prepare-for-indexing` cheapens this
  (module-only builds, continues past errors). A checkout that
  doesn't resolve at all yields partial/no data — so this can only
  ever be an **enrichment**, never the observation baseline.
- **API fits the pipeline**: synchronous, thread-safe queries —
  `occurrences(ofUSR:roles:)` with roles `.definition`, `.reference`,
  `.call`, `.overrideOf`, `.baseOf`, `.containedBy` — exactly the
  edges we want, with file/line locations to anchor observations.
- **Alternatives fall short**: symbolgraph-extract/SymbolKit gives
  declarations + structural relations but **no reference/call
  edges**; SourceKit-LSP as a client adds process management for the
  same underlying index; swift-syntax cannot resolve names across
  files.
- **Risks**: runtime `dlopen` of Xcode's `libIndexStore.dylib`
  (toolchain coupling; store format can shift with Xcode); index
  staleness vs. working tree (facts must carry unit provenance);
  C++ core wrapped behind an actor for strict concurrency.

## Recommendation

Adopt as an **optional provider** (needs owner's dependency audit):

1. New extractor/provider stage runs
   `swift build --experimental-prepare-for-indexing` under repo
   access, opens the store read-only via IndexStoreDB behind an
   actor.
2. Emits **literal observations** — "occurrence of USR X, role
   `.call`, at file:line, related USR Y" — into the observed layer.
3. CygnusDerive links USR occurrences to swift-syntax entities by
   location, producing derived reference edges. This is what turns
   the Flat view's Pattern *conventions* into Pattern *inference*.
4. Fallback when a repo doesn't build: today's swift-syntax
   extraction, degraded (no reference edges), never blocking.

Primary sources: indexstore-db repo + `Index Store.md`, SourceKit-LSP
`Package.swift` + Background Indexing docs, swift-docc-symbolkit.
