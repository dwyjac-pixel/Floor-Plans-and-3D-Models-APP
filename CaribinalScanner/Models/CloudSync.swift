import Foundation
import SwiftData

/// Launch-time convergence passes for the two independent sync pipelines
/// (CloudKit records, iCloud Drive files).
enum CloudMaintenance {
    /// Removes project folders that a synced tombstone names. A folder with
    /// no matching project row is NOT enough to delete — files can
    /// legitimately arrive before their CloudKit record — so only folders
    /// explicitly tombstoned by a delete on some device are swept. Old
    /// tombstones are pruned after 30 days.
    ///
    /// SwiftData work stays on the main actor; the file deletes hop off it
    /// (NSFileCoordinator can block behind the sync daemon).
    @MainActor
    static func sweepTombstones(context: ModelContext) {
        let tombstones = (try? context.fetch(FetchDescriptor<DeletedProject>())) ?? []
        guard !tombstones.isEmpty else { return }
        let live = (try? context.fetch(FetchDescriptor<RenovationProject>())) ?? []
        let liveFolders = Set(live.map(\.folderName))
        let pruneBefore = Date.now.addingTimeInterval(-30 * 24 * 3600)
        var foldersToSweep: [URL] = []

        for tombstone in tombstones {
            // The sample's constant folderName is shared by every seeded
            // copy; a tombstone for it could sweep a LIVE re-seeded sample
            // fleet-wide. Samples are never tombstoned (see delete) — and
            // one synced in from an older build is neutralized here.
            if tombstone.folderName == SampleProject.sampleFolderName {
                context.delete(tombstone)
                continue
            }
            if !tombstone.folderName.isEmpty, !liveFolders.contains(tombstone.folderName) {
                let folder = ScanStore.projectsRoot
                    .appendingPathComponent(tombstone.folderName, isDirectory: true)
                if FileManager.default.fileExists(atPath: folder.path) {
                    foldersToSweep.append(folder)
                }
            }
            if tombstone.deletedAt < pruneBefore {
                context.delete(tombstone)
            }
        }
        try? context.save()

        if !foldersToSweep.isEmpty {
            Task.detached(priority: .utility) {
                for folder in foldersToSweep {
                    ScanStore.coordinatedDelete(at: folder)
                }
            }
        }
    }

    /// Records a project deletion so every device sweeps its files, then
    /// performs the local delete. The one entry point for deleting a
    /// project — deleting the row without a tombstone lets an offline
    /// device's edits resurrect the folder as an invisible orphan. The
    /// file delete runs off-main; row changes stay on the main actor.
    @MainActor
    static func delete(_ project: RenovationProject, context: ModelContext) {
        let folderName = project.folderName
        if folderName != SampleProject.sampleFolderName {
            context.insert(DeletedProject(folderName: folderName))
        }
        context.delete(project)
        try? context.save()
        guard !folderName.isEmpty else { return }
        let folder = ScanStore.projectsRoot.appendingPathComponent(folderName, isDirectory: true)
        Task.detached(priority: .utility) {
            ScanStore.coordinatedDelete(at: folder)
        }
    }
}

/// Watches upload health of the cloud Projects tree. iCloud quota
/// exhaustion never fails a local write — the bytes land on disk and the
/// upload silently stalls — so without this watcher, sync death is
/// invisible: devices diverge for weeks and then mass-conflict when space
/// frees up. One banner, driven by the metadata query's uploading error.
@MainActor
final class SyncHealth: ObservableObject {
    static let shared = SyncHealth()

    @Published private(set) var storageFull = false

    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var started = false

    func start() {
        guard !started, ScanStore.isCloudRoot else { return }
        started = true
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // Match everything and inspect per-item error attributes in scan():
        // predicates keyed on NSMetadataUbiquitousItemIsUploadedKey are not
        // reliably evaluated by the metadata store.
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        query.valueListAttributes = [NSMetadataUbiquitousItemUploadingErrorKey]
        let handler: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default
                .addObserver(forName: name, object: query, queue: .main, using: handler))
        }
        query.start()
    }

    private func scan() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var full = false
        for case let item as NSMetadataItem in query.results {
            if let error = item.value(forAttribute: NSMetadataUbiquitousItemUploadingErrorKey) as? NSError,
               error.domain == NSCocoaErrorDomain,
               error.code == CocoaError.Code.ubiquitousFileNotUploadedDueToQuota.rawValue {
                full = true
                break
            }
        }
        if storageFull != full { storageFull = full }
    }
}
