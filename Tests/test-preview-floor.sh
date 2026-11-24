#!/bin/sh
# Multi-room gates for the finished preview: the sample floor and a saved
# floor joined from rooms that share a doorway. Runs on the Mac.
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -O -module-cache-path "$scratch/cache" -o "$scratch/preview-floor-tests" \
  CaribinalScanner/Models/CornerRoom.swift CaribinalScanner/Preview/*.swift Tests/PreviewReferenceFloorTests.swift
"$scratch/preview-floor-tests" "$@"
