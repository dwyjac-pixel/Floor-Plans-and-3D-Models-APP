import Foundation

/// Crash-proof breadcrumbs for diagnosing scan-start hangs: appended
/// synchronously to Caches/scan_debug.log so the trail survives a frozen UI.
/// Kept in Caches (not the file-shared Documents dir) and bounded in size so
/// it can't grow without limit or clutter the user's Files view.
enum ScanDebugLog {
    private static let maxBytes: UInt64 = 128 * 1024
    static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("scan_debug.log")

    static func log(_ message: String) {
        let line = "\(Date().description) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            // Reset once it grows past the cap rather than let it grow forever.
            if size > maxBytes {
                try? handle.truncate(atOffset: 0)
                try? handle.seek(toOffset: 0)
            }
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}
import Combine
import RoomPlan

/// Owns the RoomCaptureView and its capture session, and receives the
/// processed scan result through RoomCaptureViewDelegate.
final class ScanSessionController: NSObject, ObservableObject, RoomCaptureViewDelegate {
    @Published var didFinish = false
    @Published var didFail = false
    @Published var isProcessing = false
    @Published var errorMessage: String?
    /// Rooms banked earlier in this walk (continuous multi-room scanning).
    @Published var capturedRooms: [CapturedRoom] = []

    private(set) var finishedRoom: CapturedRoom?
    private var processingWatchdog: Task<Void, Never>?

    /// Every room from this walk, including the one currently presented.
    var walkRooms: [CapturedRoom] {
        if let finishedRoom { return capturedRooms + [finishedRoom] }
        return capturedRooms
    }

    let captureView: RoomCaptureView

    override init() {
        ScanDebugLog.log("controller.init: creating RoomCaptureView")
        captureView = RoomCaptureView(frame: .zero)
        super.init()
        captureView.delegate = self
        captureView.captureSession.delegate = self
        ScanDebugLog.log("controller.init: done")
    }

    // RoomCaptureViewDelegate inherits from NSCoding; this object is never archived.
    init?(coder: NSCoder) {
        fatalError("Archiving is not supported")
    }

    func encode(with coder: NSCoder) {}

    func start() {
        ScanDebugLog.log("start(): entered")
        processingWatchdog?.cancel()
        finishedRoom = nil
        didFinish = false
        didFail = false
        isProcessing = false
        errorMessage = nil
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        ScanDebugLog.log("start(): calling session.run")
        captureView.captureSession.run(configuration: configuration)
        ScanDebugLog.log("start(): session.run returned")
    }

    func finish() {
        isProcessing = true
        // Keep the AR session alive: a follow-up room then shares this
        // room's coordinate space, so a whole floor scans as one walk.
        captureView.captureSession.stop(pauseARSession: false)
        // RoomPlan occasionally never delivers didPresent (e.g. the session
        // died mid-scan) — without a watchdog the UI spins forever.
        processingWatchdog?.cancel()
        processingWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, self.isProcessing else { return }
            ScanDebugLog.log("watchdog: processing timed out")
            self.isProcessing = false
            self.didFail = true
            self.errorMessage = "Processing is taking too long. The scan may have been interrupted. Tap Rescan to try again."
        }
    }

    func cancel() {
        processingWatchdog?.cancel()
        captureView.captureSession.stop()
    }

    /// Banks the room just presented and immediately resumes scanning in
    /// the same AR world — the next room lands in the same coordinates.
    func scanNextRoom() {
        ScanDebugLog.log("scanNextRoom(): banking room \(capturedRooms.count + 1)")
        if let finishedRoom { capturedRooms.append(finishedRoom) }
        finishedRoom = nil
        didFinish = false
        didFail = false
        isProcessing = false
        errorMessage = nil
        processingWatchdog?.cancel()
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        captureView.captureSession.run(configuration: configuration)
        ScanDebugLog.log("scanNextRoom(): session resumed")
    }

    private func fail(with error: Error) {
        DispatchQueue.main.async {
            self.processingWatchdog?.cancel()
            self.isProcessing = false
            self.didFail = true
            if self.errorMessage == nil {
                self.errorMessage = Self.friendlyMessage(for: error)
            }
        }
    }

    /// RoomPlan's raw errors ("World tracking failure") mean nothing to a
    /// user — translate the common ones into what happened and what to do.
    static func friendlyMessage(for error: Error) -> String {
        let raw = error.localizedDescription
        if raw.localizedCaseInsensitiveContains("world tracking") {
            return "The camera lost tracking, so this scan can't be used. This usually happens when you switch apps (like taking a photo) or cover the camera mid-scan. Stay in the app for the whole scan, then tap Rescan."
        }
        return raw
    }

    // MARK: - RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        ScanDebugLog.log("shouldPresent (error: \(error?.localizedDescription ?? "none"))")
        // Returning true here after a failure makes RoomCaptureView show its
        // built-in "processing" overlay forever — bail out instead.
        if let error {
            fail(with: error)
            return false
        }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        ScanDebugLog.log("didPresent (error: \(error?.localizedDescription ?? "none"))")
        if let error {
            fail(with: error)
            return
        }
        DispatchQueue.main.async {
            self.processingWatchdog?.cancel()
            self.isProcessing = false
            self.finishedRoom = processedResult
            self.didFinish = true
        }
    }
}

// Surfaces mid-scan session failures (camera denied, tracking loss) that
// would otherwise leave a dead screen stuck on "Processing scan…".
extension ScanSessionController: RoomCaptureSessionDelegate {
    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        ScanDebugLog.log("session.didEndWith (error: \(error?.localizedDescription ?? "none"))")
        guard let error else { return }
        fail(with: error)
    }
}
