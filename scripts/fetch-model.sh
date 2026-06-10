#!/usr/bin/env bash
# Fetch the embedding model that gets compiled into the binary.
# Default is potion-base-8M (256d, ~30 MB). potion-retrieval-32M (512d,
# ~125 MB) trades size for retrieval quality; build it with
# `zig build -Dmodel=potion-retrieval-32M`.
set -euo pipefail

NAME="${1:-potion-base-8M}"
DEST="src/model/$NAME"
mkdir -p "$DEST"
for f in tokenizer.json model.safetensors; do
    if [[ ! -f "$DEST/$f" ]]; then
        echo "fetching $NAME/$f"
        curl -fsSL "https://huggingface.co/minishlab/$NAME/resolve/main/$f" -o "$DEST/$f"
    fi
done
echo "model ready in $DEST"
