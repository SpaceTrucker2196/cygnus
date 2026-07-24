# cygnus — token / cost ledger

Append-only. Rows are produced by `~/.claude/billing/ledger.py --append`
after each substantive commit. Never hand-author or estimate rows.

| date | commit | session | input tokens | output tokens | cost (USD) | summary |
|------|--------|---------|--------------|---------------|------------|---------|
| 6156659 | 2026-07-24T07:15:09Z | claude-opus-4-8 | 44915 | 33099 | 4277477 | 201690 | 5.2077 | Remove 3D rendering (Layout3D, Orbit3DView, RealityKit SpaceGraphView) — memory/ |
| bbebc3f | 2026-07-24T08:20:40Z | claude-opus-4-8 | 12216 | 172718 | 15940090 | 453075 | 16.8798 | Ops dashboard foundation: drop sandbox + git/gh subprocess tooling |
| 82c0d42 | 2026-07-24T08:26:49Z | claude-opus-4-8 | 1904 | 74671 | 9556452 | 81398 | 7.4685 | Factory value types + pure parsers |
| c9a8321 | 2026-07-24T08:31:14Z | claude-opus-4-8 | 648 | 52593 | 5201828 | 45988 | 4.3789 | Factory + docs providers over git/gh |
| a11233b | 2026-07-24T08:40:53Z | claude-opus-4-8 | 5191 | 93668 | 15016344 | 88100 | 10.7568 | Wire factory state into WorkspaceStore |
| c054889 | 2026-07-24T08:48:12Z | claude-opus-4-8 | 3116 | 82450 | 13917159 | 85931 | 9.8947 | Ops dashboard SwiftUI sections |
| 78a1de7 | 2026-07-24T08:58:21Z | claude-opus-4-8 | 4871 | 55159 | 15221611 | 67181 | 9.6859 | Fix capability/load race; auto-select repo; verify end-to-end |
| 9dac19e | 2026-07-24T20:37:19Z | claude-fable-5,claude-opus-4-8 | 75155 | 322565 | 48400132 | 1139948 | 73.5996 | 5 GB memory ceiling + bounded extraction; 2D graph grouping (area/layer/pattern) |
| fd9264f | 2026-07-24T20:38:29Z | claude-fable-5 | 598 | 9376 | 1929260 | 6651 | 2.5371 | Pages preview as portrait letter-proportioned thumbnail |
| 17618c7 | 2026-07-24T20:42:33Z | claude-fable-5 | 14 | 2251 | 1720892 | 2696 | 1.8875 | Double Pages thumbnail to 300 pt |
| a2f85ef | 2026-07-24T20:53:25Z | claude-fable-5 | 1228 | 45850 | 12105016 | 43810 | 15.2860 | Hard memory abort in engine, store-side cancel, exclude build/SourcePackages (43 |
| 9abc486 | 2026-07-24T21:00:45Z | claude-fable-5 | 1943 | 32479 | 9565130 | 35404 | 11.9166 | Detached analysis pump (UI beachball fix); walk-phase memory budget + autoreleas |
| ba50ff3 | 2026-07-24T21:04:42Z | claude-fable-5 | 679 | 16559 | 4992483 | 18697 | 6.2012 | Fix windowless launch (sampler task moved out of App-init path) |
