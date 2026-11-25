#!/bin/sh
# Fixture kinds added after 1.0.2 must survive a device that still runs
# 1.0.2. Unit checks first; then, when the 1.0.2 sources are in this
# clone's history, the real 1.0.2 room model reads and rewrites a project
# saved by this version and nothing may be lost.
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
models="CornerRoom.swift RoomsFile.swift ManualRoom.swift PlanHistory.swift PlanMarkers.swift"
current=""
for name in $models; do current="$current CaribinalScanner/Models/$name"; done
swiftc -module-cache-path "$scratch/cache" -o "$scratch/sidecar-tests" \
  $current CaribinalScanner/Models/FixtureSidecar.swift Tests/FixtureSidecarTests.swift
"$scratch/sidecar-tests"

# a875368 is 1.0.2 plus one export fix; its room model is the 1.0.2 model.
old=a875368
if git cat-file -e "$old^{commit}" 2>/dev/null; then
  mkdir "$scratch/old"
  shipped=""
  for name in $models; do
    git show "$old:CaribinalScanner/Models/$name" > "$scratch/old/$name"
    shipped="$shipped $scratch/old/$name"
  done
  swiftc -module-cache-path "$scratch/cache" -o "$scratch/old-device" $shipped Tests/FixtureSidecarOldDevice.swift
  "$scratch/sidecar-tests" write "$scratch/project"
  "$scratch/old-device" "$scratch/project"
  "$scratch/sidecar-tests" check "$scratch/project"
else
  echo "Cross version check skipped: the 1.0.2 sources ($old) are not in this clone."
fi
