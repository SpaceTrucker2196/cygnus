# cygnus — factory runbook

## Layout

- `CygnusCore/` — engine SPM package (see AGENTS.md for target rules).
- `Package.swift` + `Sources/CygnusKit/` — app-side adapter package.
- `App/` — SwiftUI macOS app, generated project via xcodegen.
- `project.yml` — authoritative project definition. `Cygnus.xcodeproj`
  is generated and gitignored.

## Commands

```
make generate    # xcodegen generate → Cygnus.xcodeproj
make build       # build the macOS app
make test        # test-engine + test-kit + test-app
make test-engine # cd CygnusCore && swift test
make test-kit    # swift test (root CygnusKit package)
make test-app    # xcodebuild -scheme Cygnus test
make clean
```

## Toolchain

Swift 6.3+ / Xcode 26.6+, macOS 15.0 deployment target (LowLevelMesh
requires it). xcodegen via Homebrew.

## Engine CLI

`cd CygnusCore && swift run cygnus <register|index|query|watch|verify>`
— the engine's harness and the fastest way to exercise the pipeline
without the app.

## Data locations

- Workspace DBs: `~/Library/Application Support/Cygnus/workspaces/<id>/`
  (`graph.sqlite` + `cas/` content-addressed blobs beside it).
- App workspace registry: `Application Support/Cygnus/workspace.json`
  (versioned Codable JSON; security-scoped bookmarks inside).

## Release

Not yet. First tagged build lands at milestone S6 (docs/milestones.md).
