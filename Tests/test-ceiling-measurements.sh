#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -module-cache-path "$scratch/cache" -o "$scratch/ceiling-tests" \
  CaribinalScanner/Models/CornerRoom.swift CaribinalScanner/Models/RoomsFile.swift \
  CaribinalScanner/Models/ManualRoom.swift CaribinalScanner/Models/SuiteCompliance.swift \
  CaribinalScanner/Models/SuiteAssessment.swift CaribinalScanner/Models/PlanningChecklist.swift \
  CaribinalScanner/Models/PlanHistory.swift CaribinalScanner/Models/PlanMarkers.swift \
  CaribinalScanner/Models/ScannerRevisionExport.swift \
  CaribinalScanner/Models/MaterialTakeoff.swift \
  CaribinalScanner/Models/Estimate.swift CaribinalScanner/Models/PriceBook.swift \
  CaribinalScanner/FloorPlan/Measure.swift Tests/CeilingMeasurementTests.swift
"$scratch/ceiling-tests" "$@"
