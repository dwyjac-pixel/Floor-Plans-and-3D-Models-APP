#!/bin/sh
# Scene level gates for the finished preview: the SceneKit room agrees
# with the layout, a finish swap changes only materials, and stills render.
# Runs on the Mac (needs a GPU), no simulator.
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -O -module-cache-path "$scratch/cache" -o "$scratch/preview-scene-tests" \
  CaribinalScanner/Models/CornerRoom.swift CaribinalScanner/Preview/*.swift Tests/PreviewSceneTests.swift
"$scratch/preview-scene-tests" "$@"
