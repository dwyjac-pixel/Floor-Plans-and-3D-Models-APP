#!/bin/sh
# Exports the reference bathroom from the doorway in every look, with a
# manifest that records the locked camera, exposure, lights and geometry.
# Usage: Tests/render-doorway-pair.sh <output folder> [width]
set -eu
cd "$(dirname "$0")/.."
out=${1:?output folder}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -O -module-cache-path "$scratch/cache" -o "$scratch/doorway-pair" \
  CaribinalScanner/Models/CornerRoom.swift CaribinalScanner/Preview/*.swift Tests/PreviewDoorwayPairMain.swift
source="branch $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown) at $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain -- CaribinalScanner/Preview 2>/dev/null)" ]; then source="$source, with uncommitted changes"; fi
"$scratch/doorway-pair" "$out" "${2:-2000}" "$source"
