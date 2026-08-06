---
title: Retrieval
summary: The agent-facing index over the graph — why it stores blob hashes instead of source, and what "unchanged costs nothing" actually rests on.
updated: 2026-08-05
---

# Retrieval

Coding agents find code by grepping and reading whole files, which is
the largest single source of wasted tokens in an agent loop. The
retrieval layer replaces that with a small number of precise queries
against what cygnus already knows.

It is an **index over the graph**, never a second copy of the system.
Every row holds a blob hash and a line range; the text is read back
from the CAS on demand. That is the test to apply to anything added
here — *does this table store text, or a pointer?* The moment a
retrieval table becomes the only place something is known, cygnus has
grown the second representation MISSION §7 forbids, and the layer has
stopped being an index and started being a rival.

## Tiers

| Tier | What it answers | Status |
|---|---|---|
| 0 — repo map | "what is this repository, ranked by importance" | planned |
| 1 — structural | definitions, references, callers, blast radius, read span | planned |
| 1a — lexical | "where does this text appear" | **shipped** |
| 2 — semantic | "where is this *idea* implemented" | planned |

## Everything is keyed by blob hash

Not by path, not by revision. This single decision is what makes the
freshness story free:

- An unchanged file re-indexes nothing.
- A **renamed** file re-indexes nothing — same blob, new row in
  `snapshot_files`.
- A **reverted** file re-indexes nothing — the blob is already there.
- The same vendored file in two repositories is indexed **once**
  between them.

The incremental update is therefore a set difference —
`manifest blobs − indexed blobs` — and nothing else is consulted. It
is stricter than `ManifestDiff.changedOrAdded`, because it also picks
up blobs a previous run failed on or was interrupted before finishing.
`cygnus watch` needs no special handling at all, and the fact that it
needs none is the evidence the primitive was the right one.

## Paths arrive at query time

Because windows carry no path, results are resolved by joining
`snapshot_files` for the newest committed snapshot of each repository.
That join is also the invalidation mechanism, and it is stronger than
a sweep: **a blob that has left the working tree cannot surface, even
before its rows are collected.** Staleness is impossible by
construction rather than corrected after the fact. `pruneOrphanBlobs`
reclaims space and never changes a result.

`snapshot_files` is `WITHOUT ROWID` keyed `(snapshot_id, path)`, so
`idx_snapshot_files_blob` is load-bearing — without it every retrieval
join scans the table end to end.

## Two blobs that will take the indexer down

Both are real, both are silent until they aren't:

- **The not-ingested sentinel.** `LocalFSProvider` records files over
  its 4 MB cap in the manifest with the hash of *empty content* and
  never stores the bytes. It is present in manifests and absent from
  the CAS, so reading it throws. It is skipped by identity
  (`RetrievalIndexer.notIngested`), not discovered by crashing on the
  first repository with a big file. Those files are a genuine
  retrieval blind spot and should be reported as one.
- **Binary blobs.** Text-ness is decodability
  (`String(data:encoding:.utf8)`), *not* the manifest's language hint —
  the hint is nil for plenty of real text (`.toml`, `.sh`, an
  extensionless `Makefile`), and decoding catches a PNG without anyone
  maintaining an allow-list.

## Why FTS5 over CAS blobs, and not ripgrep

ripgrep searches the *working tree*; the graph's evidence is the
*snapshot*. A ripgrep hit can cite a line no revision ever saw, and can
disagree with the anchors on entity versions. Everything here is
reproducible against the same blob the graph was built from.

FTS5 also gives `bm25()`, which a fusion step needs — ripgrep returns
matches, not a ranking. The cost is regex: FTS5 has none. If that
becomes necessary, add it as a clearly-labelled working-tree tool that
does *not* claim snapshot consistency, so nobody confuses the two.

## The split column

`unicode61` treats `withThrowingTaskGroup` as one indivisible token, so
a search for "task group" — the way a person actually asks — matches
nothing. Every window is therefore indexed twice: `body` verbatim, and
`body_split` with identifiers broken at case, underscore and
digit boundaries (`HTTPClient` → `HTTP Client`). `bm25(source_search,
1.0, 0.4)` weights the verbatim column higher, so an exact match still
outranks a split one.

Measured on cygnus itself: of the windows matching `Throwing`, **7 of
10 are reachable only through the split column**; for `Deriver`, 8.
Without it the lexical tier only finds what the searcher could already
spell exactly.

## Citations are exact, not window-sized

Windows are 60 lines with no overlap — overlap inflates the index and
double-counts BM25. A 60-line citation would be useless, so precision
comes back at query time: the window is re-read from the CAS, the line
that actually matched is located, and *that* is what gets cited, with
two lines of context either side.

## Measured (cygnus, 2026-08-05)

230 files → 223 indexed blobs, 27,671 lines, 577 windows. Re-indexing
an unchanged tree writes **zero** rows. `cygnus verify` is clean: the
retrieval pass mints no revision and asserts no facts.

    cygnus search "withThrowingTaskGroup"      # exact identifier
    cygnus search "throwing task group" 5      # split match
