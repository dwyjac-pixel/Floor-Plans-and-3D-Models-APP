#!/bin/sh
# Renders the reference bathroom on the Mac in every look, from every
# camera stop. Usage: Tests/render-preview-stills.sh <output folder> [width]
set -eu
cd "$(dirname "$0")/.."
out=${1:?output folder}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -O -module-cache-path "$scratch/cache" -o "$scratch/preview-stills" \
  CaribinalScanner/Models/CornerRoom.swift CaribinalScanner/Preview/*.swift Tests/PreviewStillMain.swift
"$scratch/preview-stills" "$out" "${2:-1600}"
