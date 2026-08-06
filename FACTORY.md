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

Retrieval subcommands, all reading the indexed snapshot rather than the
working tree: `search <text>`, `def <symbol>`, `refs <symbol>`,
`callers <symbol>`, `radius <symbol>`, `span <path> <a> <b>`,
`map [repo] [focus…]`.

## MCP server (the agent-facing surface)

```
make install-mcp     # release cygnus-mcp + cygnus into ~/.local/bin
make index-factory   # register + index FACTORY_REPOS into the default workspace
```

`.mcp.json` at the repo root registers the server with Claude Code. It
names `cygnus-mcp` on PATH rather than a build path, because an
absolute `.build/…` path breaks on the next `make clean`. (One of the
few files that must sit at the repo root — the tooling looks there.)

`CYGNUS_WORKSPACE` points it elsewhere; unset, it uses the same default
workspace the CLI does, so `make index-factory` and the server always
agree about what is indexed.

Nine tools: `status`, `repo_map`, `search`, `find_definition`,
`find_references`, `callers_of`, `blast_radius`, `list_symbols`,
`read_span`. Design and the token-budget contract live in
`docs/wiki/retrieval.md`.

Smoke-test without a client:

```
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"cygnus_status","arguments":{}}}' \
  | cygnus-mcp
```

## Data locations

- Workspace DBs: `~/Library/Application Support/Cygnus/workspaces/<id>/`
  (`graph.sqlite` + `cas/` content-addressed blobs beside it).
- App workspace registry: `Application Support/Cygnus/workspace.json`
  (versioned Codable JSON; security-scoped bookmarks inside).

## Release

Not yet. First tagged build lands at milestone S6 (docs/milestones.md).
