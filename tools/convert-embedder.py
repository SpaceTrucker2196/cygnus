#!/usr/bin/env python3
"""Convert a HuggingFace sentence encoder to Core ML for cygnus.

This is the one Python file in a repository of Swift tools, and it is
here because coremltools is Python-only. It is a **developer script**:
it never runs during a build, never runs in `make test`, and nothing in
the package depends on it. Run it once, keep the output, forget it.

    pip install 'coremltools>=8.0' 'transformers>=4.40' torch
    python3 tools/convert-embedder.py \
        --model jinaai/jina-embeddings-v2-base-code \
        --out ~/Library/Application\\ Support/Cygnus/workspaces/default/models/jina-code

Then either leave it in the workspace's `models/` directory, where
cygnus finds it automatically, or point `CYGNUS_EMBED_MODEL` at it.

Why a code-specific model by default: general-purpose text embedders
collapse on repository-level retrieval — the published gap is several
times the score of code-tuned models — so defaulting to a general model
would reproduce the "code embeds badly" folk wisdom by construction.
The seam takes any encoder; the default should be one trained on code.

The output directory is what `CoreMLEmbedder` expects:

    model.mlmodelc/     compiled Core ML model
    vocab.txt           the tokenizer vocabulary, unchanged
    descriptor.json     dimension, window, prefixes, artifact hash
"""

import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

DEFAULT_MODEL = "jinaai/jina-embeddings-v2-base-code"


def die(message):
    print(f"convert-embedder: {message}", file=sys.stderr)
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default=DEFAULT_MODEL,
                        help=f"HuggingFace model id (default: {DEFAULT_MODEL})")
    parser.add_argument("--out", required=True, help="output directory")
    parser.add_argument("--max-tokens", type=int, default=256,
                        help="input width; chunks are ~120 lines, 256 is ample")
    parser.add_argument("--query-prefix", default="",
                        help="prepended to queries (e5 wants 'query: ')")
    parser.add_argument("--document-prefix", default="",
                        help="prepended to documents (e5 wants 'passage: ')")
    parser.add_argument("--enumerated-shapes", action="store_true",
                        help="bucket input widths (64/128/max) for throughput. Off by "
                             "default: models with dynamic position bias such as ALiBi "
                             "compute from the sequence length, and a symbolic length "
                             "cannot be converted")
    parser.add_argument("--trust-remote-code", action="store_true",
                        help="execute the model's own Python from the Hub. Required by "
                             "models with custom architectures (jina-v2, nomic, codet5p) "
                             "and off by default because it runs third-party code")
    arguments = parser.parse_args()

    try:
        import numpy as np
        import torch
        import coremltools as ct
        from transformers import AutoConfig, AutoModel, AutoTokenizer
    except ImportError as error:
        die(f"missing dependency ({error}). "
            "pip install 'coremltools>=8.0' 'transformers>=4.40' torch")

    out = pathlib.Path(arguments.out).expanduser()
    out.mkdir(parents=True, exist_ok=True)

    print(f"loading {arguments.model} …")
    tokenizer = AutoTokenizer.from_pretrained(
        arguments.model, trust_remote_code=arguments.trust_remote_code)

    config = AutoConfig.from_pretrained(
        arguments.model, trust_remote_code=arguments.trust_remote_code)

    # Check BEFORE loading, not after. A custom architecture loaded as
    # stock BERT is the worst outcome available here — conversion
    # succeeds, vectors come out, and they mean the wrong thing — and
    # in newer transformers it does not even get that far, failing on a
    # config mismatch whose message says nothing about the real cause.
    auto_map = getattr(config, "auto_map", None)
    if auto_map and not arguments.trust_remote_code:
        sources = sorted({value.split("--")[0] for value in auto_map.values()
                          if "--" in value}) or [arguments.model]
        die(f"{arguments.model} defines a custom architecture and cannot be loaded "
            "as a stock one.\n\n"
            f"  needs: {auto_map.get('AutoModel', 'custom code')}\n"
            f"  code from: {', '.join(sources)}\n\n"
            "Re-run with --trust-remote-code to execute that code from the Hub, or "
            "choose a model with a stock architecture:\n"
            "  --model BAAI/bge-base-en-v1.5          (768d, stock BERT, general purpose)\n"
            "  --model sentence-transformers/all-MiniLM-L6-v2   (384d, small, general)\n\n"
            "Executing Hub code is a supply-chain decision, which is why it is not "
            "the default. Note the code above may come from a *different* repository "
            "than the weights.")

    # Eager attention, not SDPA. Newer transformers default to a scaled
    # dot-product path whose graph coremltools cannot lower — it hits an
    # int() cast on a non-scalar and dies with a message naming neither.
    # Eager is the traceable implementation.
    model = AutoModel.from_pretrained(
        arguments.model, config=config,
        attn_implementation="eager",
        trust_remote_code=arguments.trust_remote_code).eval()
    print(f"  architecture: {type(model).__name__}")

    width = arguments.max_tokens

    # A thin wrapper with a fixed positional signature, returning just
    # the hidden states. Core ML has no use for the rest of the output
    # object, and naming the inputs here is what names them in the
    # converted model.
    class Encoder(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, input_ids, attention_mask, token_type_ids):
            return self.inner(input_ids=input_ids,
                              attention_mask=attention_mask,
                              token_type_ids=token_type_ids).last_hidden_state

    example = (torch.ones(1, width, dtype=torch.int32),
               torch.ones(1, width, dtype=torch.int32),
               torch.zeros(1, width, dtype=torch.int32))

    # torch.export, not torch.jit.trace.
    #
    # This is the whole reason conversion works. The trace frontend
    # turns a transformer's shape arithmetic — `batch_size, seq_length
    # = input_ids.size()` — into an aten::Int over a rank-1 array, and
    # coremltools dies calling int() on it with a message that names
    # neither the model nor the op. That failure is identical across
    # every model, input shape, attention implementation, transformers
    # version and coremltools/torch pair we tried; the frontend was
    # always the variable. torch.export lowers the same graph cleanly.
    print("exporting …")
    exported = torch.export.export(Encoder(model).eval(), example)

    print("converting to Core ML …")
    # A fixed width by default. Bucketing input widths is close to a 2x
    # throughput win, but it makes the sequence length symbolic, and a
    # model whose position bias is computed from that length — ALiBi, as
    # in jina-v2 — hits `int()` on a symbolic value and fails to
    # convert. Every chunk padding to full width is the cost of
    # supporting those models at all.
    # Input names and shapes come from the exported program, so they do
    # not need restating here.
    converted = ct.convert(
        exported,
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
    )

    package = out / "model.mlpackage"
    if package.exists():
        shutil.rmtree(package)
    converted.save(str(package))

    print("compiling …")
    compiled = out / "model.mlmodelc"
    if compiled.exists():
        shutil.rmtree(compiled)
    # xcrun coremlcompiler produces the .mlmodelc CoreMLEmbedder loads.
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(out)],
                   check=True)

    # The tokenizer vocabulary, verbatim: WordPiece.swift must agree
    # with it exactly or embeddings are subtly wrong rather than broken.
    vocabulary = out / "vocab.txt"
    saved = tokenizer.save_vocabulary(str(out))
    if saved and pathlib.Path(saved[0]) != vocabulary:
        shutil.copy(saved[0], vocabulary)
    if not vocabulary.exists():
        die("the tokenizer did not emit a vocab.txt — is it WordPiece-based?")

    digest = hashlib.sha256()
    for path in sorted(compiled.rglob("*")):
        if path.is_file():
            digest.update(path.read_bytes())
    sha = digest.hexdigest()

    descriptor = {
        "name": arguments.model.split("/")[-1],
        "dimension": int(model.config.hidden_size),
        "maxTokens": width,
        "queryPrefix": arguments.query_prefix,
        "documentPrefix": arguments.document_prefix,
        "sha256": sha,
        "converter": f"coremltools {ct.__version__}, torch {torch.__version__}",
    }
    (out / "descriptor.json").write_text(json.dumps(descriptor, indent=2) + "\n")

    print(f"\nwrote {out}")
    print(f"  model  {descriptor['name']} ({descriptor['dimension']}d, {width} tokens)")
    print(f"  id     {descriptor['name']}@{sha[:8]}")
    print("\nRecord this in MISSION.md §5 (licence, source, sha256) and "
          "PROGRESS.md before relying on it — the weights are a "
          "third-party artifact even though they are not a code dependency.")


if __name__ == "__main__":
    main()
