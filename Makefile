# Convenience wrappers. See FACTORY.md for full details.

XCODEGEN   := xcodegen
SWIFT      := swift
XCODEBUILD := xcodebuild

PROJECT := Cygnus.xcodeproj
SCHEME  := Cygnus
DEST    := platform=macOS

.PHONY: all generate build test test-engine test-kit test-app clean

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

clean:
	rm -rf .build CygnusCore/.build DerivedData $(PROJECT)
