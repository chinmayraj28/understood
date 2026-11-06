#!/bin/sh
# Copies the masters at the repo root into this package's resources.
# The masters are the files to edit; the copies are what the app bundles.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
dest="$here/Sources/HFMemory/Resources"
cp "$root/Fixtures/recipes.json" "$dest/recipes.json"
cp "$root/Fixtures/memory_tools.json" "$dest/memory_tools.json"
cp "$root/docs/prompts/memory_learning.md" "$dest/memory_learning.md"
echo "Copied recipes.json, memory_tools.json and memory_learning.md into $dest"
