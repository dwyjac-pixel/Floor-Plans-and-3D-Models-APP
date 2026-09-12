import SwiftUI
import SwiftData

@main
struct CaribinalScannerApp: App {
    let container: ModelContainer
    /// Which tier the store landed on: "cloud" (CloudKit sync), "local"
    /// (data intact, sync off), or "memory" (last resort).
    let storeMode: String

    /// Gates the UI: many screens read ScanStore synchronously in their
    /// inits, so the storage root must be pinned before ANYTHING renders —
    /// otherwise a root switch mid-session would split reads and writes
    /// across two trees (stale screens saving defaults over real files).
    @State private var storageReady = false

    /// A .cbproj opened from Files/AirDrop can arrive at cold launch,
    /// before the gate lifts. Buffer it here and let the list consume it
    /// once storage is ready — importing pre-bootstrap would write into
    /// the wrong root.
    @State private var pendingImportURL: URL?

    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.appearanceKey) private var appearance = "system"

    init() {
        ScanDebugLog.log("boot: app init entered")
        let schema = Schema([RenovationProject.self, DeletedProject.self])
        let cloud = ModelConfiguration(schema: schema,
                                       cloudKitDatabase: .private(ScanStore.cloudContainerID))
        ScanDebugLog.log("boot: trying cloud ModelContainer")
        if let c = try? ModelContainer(for: schema, configurations: [cloud]) {
            ScanDebugLog.log("boot: cloud ModelContainer ready")
            container = c
            storeMode = "cloud"
        } else if let c = try? ModelContainer(for: schema,
                                              configurations: [ModelConfiguration(schema: schema,
                                                                                  cloudKitDatabase: .none)]) {
            // Entitlement missing or CloudKit validation failed: keep the
            // user's data working locally rather than crashing.
            container = c
            storeMode = "local"
        } else {
            container = try! ModelContainer(for: schema,
                                            configurations: [ModelConfiguration(schema: schema,
                                                                                isStoredInMemoryOnly: true)])
            storeMode = "memory"
        }
        print("CaribinalScanner store mode: \(storeMode)")
        ScanDebugLog.log("boot: app init done, store mode \(storeMode)")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if storageReady {
                    ProjectListView(storeMode: storeMode,
                                    pendingImportURL: $pendingImportURL)
                        .task { runConvergencePasses(initial: true) }
                } else {
                    ProgressView("Preparing your projects…")
                        .task {
                            ScanDebugLog.log("boot: bootstrap begin")
                            await ScanStore.bootstrap()
                            ScanDebugLog.log("boot: bootstrap end")
                            storageReady = true
                        }
                }
            }
            .onOpenURL { pendingImportURL = $0 }
            .tint(Color(red: 0.80, green: 0.28, blue: 0.33))
            .preferredColorScheme(AppSettings.colorScheme(appearance))
            .onChange(of: scenePhase) { _, phase in
                // CloudKit imports land mid-session; re-converge whenever
                // the app returns to the foreground.
                if phase == .active, storageReady { runConvergencePasses(initial: false) }
            }
        }
        .modelContainer(container)
    }

    private func runConvergencePasses(initial: Bool) {
        // An in-memory store is a temporary emergency shell — seeding it
        // would burn the one-shot seed flag and write files that a healthy
        // relaunch then has to reconcile.
        guard storeMode != "memory" else { return }
        if initial {
            SampleProject.seedIfNeeded(context: container.mainContext)
            SampleProject.ensureSampleGeometry(context: container.mainContext)
            SyncHealth.shared.start()
        }
        SampleProject.dedupeSamples(context: container.mainContext)
        SampleProject.retitleLegacySample(context: container.mainContext)
        CloudMaintenance.sweepTombstones(context: container.mainContext)
    }
}
