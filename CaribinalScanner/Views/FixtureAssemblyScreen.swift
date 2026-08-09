import SwiftUI

/// Manager for the user's saved fixture assemblies — the reusable groups of
/// fixtures ("Standard 3-pc bath") created from the fixture Catalog. Lists
/// every saved assembly with the fixtures it contains and allows deletion,
/// persisting each change through `AssemblyStore`.
///
/// Placement of an assembly into a room stays in the Catalog's "My
/// Assemblies" flow (which already recentres the group in the selected room);
/// wiring placement in from here would mean threading the plan editor's
/// gesture/persist pipeline through a pushed screen, so it is intentionally
/// left as a follow-up. This screen is view + delete only.
struct FixtureAssemblyScreen: View {
    @State private var assemblies: [FixtureAssembly]
    /// Called with the surviving list after a delete, so the presenter can
    /// keep its own cached copy of the assemblies in sync with disk.
    var onChange: (([FixtureAssembly]) -> Void)?

    init(onChange: (([FixtureAssembly]) -> Void)? = nil) {
        _assemblies = State(initialValue: AssemblyStore.load())
        self.onChange = onChange
    }

    var body: some View {
        List {
            if assemblies.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Saved Assemblies",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Save a room's fixtures from the fixture Catalog to reuse them across projects.")
                    )
                }
            } else {
                Section {
                    ForEach(assemblies) { assembly in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(assembly.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(fixtureSummary(for: assembly))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(assembly.name), \(fixtureSummary(for: assembly))")
                    }
                    .onDelete(perform: delete)
                } header: {
                    Text("Saved Assemblies")
                } footer: {
                    Text("Swipe a row to delete. To drop an assembly into a room, open the fixture Catalog and pick it from My Assemblies.")
                }
            }
        }
        .navigationTitle("Saved Assemblies")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !assemblies.isEmpty {
                EditButton()
            }
        }
    }

    /// A plain-language list of the fixture kinds in an assembly, collapsing
    /// repeats into counts — e.g. "2× Base Cabinets & Countertop, Toilet".
    private func fixtureSummary(for assembly: FixtureAssembly) -> String {
        guard !assembly.fixtures.isEmpty else { return "No fixtures" }
        var order: [CornerRoom.Fixture.Kind] = []
        var counts: [CornerRoom.Fixture.Kind: Int] = [:]
        for fixture in assembly.fixtures {
            if counts[fixture.kind] == nil { order.append(fixture.kind) }
            counts[fixture.kind, default: 0] += 1
        }
        return order.map { kind in
            let count = counts[kind] ?? 0
            return count > 1 ? "\(count)× \(kind.rawValue)" : kind.rawValue
        }.joined(separator: ", ")
    }

    private func delete(_ offsets: IndexSet) {
        var updated = assemblies
        updated.remove(atOffsets: offsets)
        AssemblyStore.save(updated)
        assemblies = updated
        onChange?(updated)
    }
}
