#!/usr/bin/env bash
# One-time setup for cygnus's semantic search tier.
#
# Builds an isolated Python environment, downloads a code embedding
# model, converts it to Core ML, and installs it where cygnus looks.
# Nothing here runs during a build or during `make test`; the whole
# point is that it runs once and then never again.
#
#   ./tools/setup-embedder.sh              # convert the default model
#   ./tools/setup-embedder.sh --dry-run    # show what it would download
#
# Everything lands under a scratch venv and the workspace's models/
# directory. Remove both to undo it completely.

set -euo pipefail

MODEL="${MODEL:-jinaai/jina-embeddings-v2-base-code}"
WORKSPACE="${CYGNUS_WORKSPACE:-$HOME/Library/Application Support/Cygnus/workspaces/default}"
OUT="${OUT:-$WORKSPACE/models/$(basename "$MODEL")}"
VENV="${VENV:-$HOME/.cache/cygnus-embedder-venv}"
DRY_RUN=0

for argument in "$@"; do
    case "$argument" in
        --dry-run) DRY_RUN=1 ;;
        --model=*) MODEL="${argument#*=}"; OUT="$WORKSPACE/models/$(basename "$MODEL")" ;;
        --out=*) OUT="${argument#*=}" ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $argument" >&2; exit 2 ;;
    esac
done

say() { printf '\033[1m→ %s\033[0m\n' "$*"; }

# coremltools and torch lag behind the newest CPython by a release or
# two, and the default python3 here is often newer than either supports.
# Pick a version known to have wheels rather than discovering the gap
# halfway through a multi-gigabyte install.
PYTHON=""
for candidate in python3.12 python3.11 python3.10; do
    if command -v "$candidate" >/dev/null 2>&1; then PYTHON="$candidate"; break; fi
done
if [ -z "$PYTHON" ]; then
    echo "No suitable Python found. coremltools needs 3.10–3.12; $(python3 --version) is" >&2
    echo "too new for its wheels. Install one:  brew install python@3.12" >&2
    exit 1
fi

say "Python:    $PYTHON ($($PYTHON --version))"
say "Model:     $MODEL"
say "Output:    $OUT"
say "Venv:      $VENV"

cat <<'SIZES'

This downloads, roughly:

  torch                ~1–2 GB installed (the bulk of it)
  coremltools          ~50 MB
  transformers + deps  ~100 MB
  model weights        ~300–700 MB from HuggingFace

Expect 2–4 GB of disk and a few minutes on a fast connection. The venv
is scratch and can be deleted afterwards; only the converted model in
the workspace is needed at runtime.

The weights are third-party. Check the model's licence before relying
on it, and record licence, source and hash in MISSION.md §5 — they are
an artifact even though they are not a code dependency.

SIZES

if [ "$DRY_RUN" -eq 1 ]; then
    say "Dry run — nothing downloaded."
    exit 0
fi

printf 'Continue? [y/N] '
read -r reply
case "$reply" in [yY]*) ;; *) echo "aborted"; exit 0 ;; esac

if [ ! -d "$VENV" ]; then
    say "Creating venv"
    if command -v uv >/dev/null 2>&1; then
        uv venv --python "$PYTHON" "$VENV"
    else
        "$PYTHON" -m venv "$VENV"
    fi
fi

say "Installing dependencies"
# Pinned, and the pins are load-bearing rather than cautious.
#
#   transformers <5 — models publishing custom architectures (jina,
#     nomic) target the 4.x API. On 5.x their Hub code fails importing
#     symbols that were removed, e.g. find_pruneable_heads_and_indices.
#   torch 2.7 — the newest release coremltools has actually tested
#     against; anything later warns and may convert incorrectly rather
#     than failing.
#
# This is a converter for third-party model code, so it lives at the
# intersection of three release trains and floats badly. Raise a pin
# only after a conversion succeeds with it.
DEPS=('coremltools>=8.0,<10' 'transformers>=4.40,<5' 'torch==2.7.0')
if command -v uv >/dev/null 2>&1; then
    VIRTUAL_ENV="$VENV" uv pip install "${DEPS[@]}"
else
    "$VENV/bin/pip" install --upgrade pip >/dev/null
    "$VENV/bin/pip" install "${DEPS[@]}"
fi

say "Converting (downloads the model on first run)"
mkdir -p "$(dirname "$OUT")"
"$VENV/bin/python" "$(dirname "$0")/convert-embedder.py" --model "$MODEL" --out "$OUT"

say "Verifying"
for required in model.mlmodelc vocab.txt descriptor.json; do
    if [ ! -e "$OUT/$required" ]; then
        echo "conversion incomplete: $OUT/$required is missing" >&2
        exit 1
    fi
done

cat <<DONE

Installed to:
  $OUT

cygnus finds it automatically when it sits under the workspace's
models/ directory. Verify with:

  cygnus-mcp <<< '{"jsonrpc":"2.0","id":1,"method":"initialize"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"cygnus_status","arguments":{}}}'

Semantic search should now read "ready" rather than "unavailable". Then
build the vectors — chunking is incremental, so this is only slow once:

  cygnus index

DONE
