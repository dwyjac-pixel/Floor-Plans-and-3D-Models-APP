#!/bin/sh
# Model to drawing checks for the finished preview. Pure Swift, runs on
# the Mac in a few seconds with no simulator.
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -module-cache-path "$scratch/cache" -o "$scratch/preview-tests" \
  CaribinalScanner/Models/CornerRoom.swift \
  CaribinalScanner/Preview/PreviewLayout.swift CaribinalScanner/Preview/PreviewCamera.swift \
  CaribinalScanner/Preview/PreviewFinishes.swift CaribinalScanner/Preview/PreviewReferenceRoom.swift \
  Tests/PreviewGeometryTests.swift
"$scratch/preview-tests" "$@"
