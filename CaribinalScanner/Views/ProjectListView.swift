import SwiftUI
import SwiftData

struct ProjectListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RenovationProject.createdAt, order: .reverse) private var projects: [RenovationProject]
    @State private var showingNewProject = false
    @State private var showingBusinessProfile = false
    @State private var showingImporter = false
    @State private var importMessage: String?
    @State private var isImporting = false
    @State private var pendingDeletion: RenovationProject?
    @State private var selectedProject: RenovationProject?
    @State private var searchText = ""

    private var filteredProjects: [RenovationProject] {
        guard !searchText.isEmpty else { return Array(projects) }
        let query = searchText.lowercased()
        return projects.filter {
            $0.name.lowercased().contains(query)
                || $0.clientName.lowercased().contains(query)
                || $0.address.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if projects.isEmpty {
                    ContentUnavailableView(
                        "No Projects",
                        systemImage: "house",
                        description: Text("Tap + to create your first project, then scan the space on site.")
                    )
                } else if filteredProjects.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(selection: $selectedProject) {
                        ForEach(filteredProjects) { project in
                            ProjectRow(project: project)
                                .tag(project)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Caribinal Scanner")
            .searchable(text: $searchText, prompt: "Client, address, or project")
            .toolbar {
                Menu {
                    Button {
                        showingBusinessProfile = true
                    } label: {
                        Label("Business Profile", systemImage: "gearshape")
                    }
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import Project Backup…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More options")
                Button {
                    showingNewProject = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Project")
            }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.data, .item]) { result in
                switch result {
                case .success(let url):
                    importBackup(from: url)
                case .failure(let error):
                    importMessage = error.localizedDescription
                }
            }
            .alert("Import Backup", isPresented: Binding(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importMessage ?? "")
            }
            .onOpenURL { handleIncomingBackup($0) }
            .sheet(isPresented: $showingBusinessProfile) {
                BusinessProfileScreen()
            }
            .sheet(isPresented: $showingNewProject) {
                NewProjectSheet()
            }
            .confirmationDialog("Delete Project",
                                isPresented: Binding(
                                    get: { pendingDeletion != nil },
                                    set: { if !$0 { pendingDeletion = nil } }
                                ),
                                titleVisibility: .visible,
                                presenting: pendingDeletion) { project in
                Button("Delete \"\(project.name)\"", role: .destructive) {
                    if selectedProject == project { selectedProject = nil }
                    ScanStore.deleteAllFiles(for: project)
                    modelContext.delete(project)
                }
                Button("Cancel", role: .cancel) {}
            } message: { project in
                Text("All scans and photos for \"\(project.name)\" are permanently removed. This can't be undone.")
            }
            .overlay {
                if isImporting {
                    ProgressView("Importing…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        } detail: {
            if let selectedProject {
                ProjectDetailView(project: selectedProject)
            } else {
                ContentUnavailableView(
                    "Select a Project",
                    systemImage: "house",
                    description: Text("Choose a project from the list to view its details, scans, and estimate.")
                )
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        // Confirm before destroying files — the in-detail delete warns too.
        pendingDeletion = offsets.first.map { filteredProjects[$0] }
    }

    /// Import off the main thread on a background SwiftData context so the
    /// whole project folder isn't deserialized in memory on the main thread
    /// (QA-034); the save lands in the shared store and the @Query updates.
    private func importBackup(from url: URL) {
        guard !isImporting else { return }
        isImporting = true
        let container = modelContext.container
        Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            do {
                let project = try ProjectBackup.importBackup(from: url, into: context)
                let name = project.name
                await MainActor.run {
                    importMessage = "\"\(name)\" imported with all its files."
                    isImporting = false
                }
            } catch {
                await MainActor.run {
                    importMessage = error.localizedDescription
                    isImporting = false
                }
            }
        }
    }

    /// Opens a .cbproj backup handed to the app from Files / Mail / AirDrop
    /// (via the declared document type). Such URLs are security-scoped and
    /// live outside the sandbox, so copy the file in under access before the
    /// asynchronous import reads it.
    private func handleIncomingBackup(_ url: URL) {
        guard url.pathExtension.lowercased() == "cbproj" else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".cbproj")
        do {
            try FileManager.default.copyItem(at: url, to: temp)
        } catch {
            importMessage = "Couldn't open the backup: \(error.localizedDescription)"
            return
        }
        importBackup(from: temp)
    }
}

struct ProjectRow: View {
    let project: RenovationProject

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "house.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.headline)
                if !project.address.isEmpty {
                    Text(project.address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    StatusChip(prefix: "Est", text: project.estimateStatus)
                    StatusChip(prefix: "Permit", text: project.permitStatus)
                    if project.scanDate != nil {
                        Label("Captured", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityDescription: String {
        var parts: [String] = [project.name]
        if !project.clientName.isEmpty { parts.append("Client \(project.clientName)") }
        if !project.address.isEmpty { parts.append(project.address) }
        parts.append("Estimate \(project.estimateStatus)")
        parts.append("Permit \(project.permitStatus)")
        if project.scanDate != nil { parts.append("Captured") }
        return parts.joined(separator: ", ")
    }
}

struct StatusChip: View {
    let prefix: String
    let text: String

    var body: some View {
        Text("\(prefix): \(text)")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch text {
        case "Approved": .green
        case "Sent", "Submitted": .blue
        case "Draft", "Preparing": .orange
        default: .secondary
        }
    }
}
