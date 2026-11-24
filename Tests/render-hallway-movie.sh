#!/bin/sh
# Render the reference hallway crossing as a 30 fps MP4.
set -eu
cd "$(dirname "$0")/.."
output=${1:?absolute output MP4 path required}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -O -module-cache-path "$scratch/cache" -o "$scratch/hallway" \
  CaribinalScanner/Models/CornerRoom.swift CaribinalScanner/Preview/*.swift Tests/PreviewHallwayMovie.swift
"$scratch/hallway" "$output"
