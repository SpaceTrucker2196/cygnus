# Convenience wrappers. See FACTORY.md for full details.

XCODEGEN   := xcodegen
SWIFT      := swift
XCODEBUILD := xcodebuild

PROJECT := Cygnus.xcodeproj
SCHEME  := Cygnus
DEST    := platform=macOS

# Where `install-mcp` puts the binaries. ~/.local/bin needs no sudo;
# override with `make install-mcp PREFIX=/usr/local` if you prefer.
PREFIX ?= $(HOME)/.local

# SwiftPM symlinks .build/release to the current triple's directory.
RELEASE := CygnusCore/.build/release

.PHONY: all generate build test test-engine test-kit test-app clean \
        mcp install-mcp index-factory

all: generate build

# Regenerate the Xcode project from project.yml.
generate:
	$(XCODEGEN) generate

# Build the macOS app (regenerates first).
build: generate
	$(XCODEBUILD) -scheme $(SCHEME) -destination '$(DEST)' build

# All tests: engine package, app-side kit package, Xcode unit tests.
test: test-engine test-kit test-app

# Engine tests. No Xcode required. Coverage always on — the app's
# coverage-halo mode reads the resulting codecov artifact.
test-engine:
	cd CygnusCore && $(SWIFT) test --enable-code-coverage

# App-side adapter package tests. No Xcode required. Coverage always
# on, same reason.
test-kit:
	$(SWIFT) test --enable-code-coverage

# Xcode unit tests (requires xcodegen + Xcode).
test-app: generate
	$(XCODEBUILD) -scheme $(SCHEME) -destination '$(DEST)' test

# The agent-facing surface: a release build of the MCP server and the
# CLI harness beside it.
mcp:
	cd CygnusCore && $(SWIFT) build -c release --product cygnus-mcp
	cd CygnusCore && $(SWIFT) build -c release --product cygnus

# Put both on PATH so .mcp.json can name `cygnus-mcp` without an
# absolute build path that breaks on the next `make clean`.
# `.build/release` is a symlink SwiftPM creates for the current triple.
install-mcp: mcp
	install -d $(PREFIX)/bin
	install -m 755 $(RELEASE)/cygnus-mcp $(PREFIX)/bin/cygnus-mcp
	install -m 755 $(RELEASE)/cygnus $(PREFIX)/bin/cygnus
	@echo "installed to $(PREFIX)/bin — ensure it is on PATH"

# Register and index the repositories the factory actually runs, into
# the default workspace the MCP server reads. Safe to re-run: indexing
# is incremental and unchanged repositories cost nothing.
index-factory: mcp
	@for repo in $(FACTORY_REPOS); do \
		echo "→ $$repo"; \
		$(RELEASE)/cygnus register "$$repo" >/dev/null 2>&1 || true; \
	done
	$(RELEASE)/cygnus index

FACTORY_REPOS ?= \
	$(HOME)/projects/cygnus \
	$(HOME)/projects/sloth \
	$(HOME)/projects/otter \
	$(HOME)/projects/henge \
	$(HOME)/projects/DF_Template

clean:
	rm -rf .build CygnusCore/.build DerivedData $(PROJECT)
