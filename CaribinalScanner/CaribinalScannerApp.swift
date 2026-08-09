import SwiftUI
import SwiftData

@main
struct CaribinalScannerApp: App {
    let container: ModelContainer

    init() {
        container = try! ModelContainer(for: RenovationProject.self)
    }

    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .tint(Color(red: 0.80, green: 0.28, blue: 0.33))
                .task {
                    SampleProject.seedIfNeeded(context: container.mainContext)
                }
        }
        .modelContainer(container)
    }
}
