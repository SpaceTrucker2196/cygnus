# cygnus

Repositories, understood. Cygnus models a software system — not its
files — as a Knowledge Graph built from repository evidence, and
renders it as a navigable 3D space. Native macOS, local-first, by
[river.io](https://river.io).

- Engine: `CygnusCore/` (SPM). Immutable graph revisions over SQLite,
  content-addressed snapshots, observation pipeline, extractors for
  Swift / Python / C, full provenance.
- App: SwiftUI shell in `App/`, adapter layer in `Sources/CygnusKit/`.

Start here: `MISSION.md` (charter), `docs/architecture.md` (plan of
record), `FACTORY.md` (build runbook), `docs/milestones.md` (roadmap).

```
make test    # engine + kit + app tests
make build   # macOS app
```
