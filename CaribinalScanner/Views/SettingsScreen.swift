import SwiftUI

/// One place for every app-wide preference, plus the business screens that
/// were previously scattered behind other features (Price Book lived only
/// behind Quick Estimate).
struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.appearanceKey) private var appearance = "system"
    @AppStorage("useImperialUnits") private var useImperial = true
    @AppStorage(AppSettings.labels3DKey) private var show3DLabels = true
    @AppStorage(AppSettings.wall3DHexKey) private var wall3DHex = ""
    @AppStorage(AppSettings.defaultCeilingKey) private var defaultCeiling = 2.4
    @State private var showingBusinessProfile = false

    private let ceilingChoices: [Double] = [2.13, 2.29, 2.4, 2.44, 2.59, 2.74, 3.05]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Theme", selection: $appearance) {
                        Text("Match iPhone").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                } header: {
                    Text("Appearance")
                }

                Section {
                    Picker("Measurements", selection: $useImperial) {
                        Text("Feet & inches").tag(true)
                        Text("Metres").tag(false)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Units")
                } footer: {
                    Text("Applies everywhere: plans, 3D models, estimates, and every export.")
                }

                Section {
                    ColorPicker("Unpainted wall colour",
                                selection: wallColorBinding, supportsOpacity: false)
                    if !wall3DHex.isEmpty {
                        Button("Reset Wall Colour") { wall3DHex = "" }
                    }
                    Toggle("Show measurements", isOn: $show3DLabels)
                } header: {
                    Text("3D Model")
                } footer: {
                    Text("Per-wall paint set in the editor always wins. This is the default finish. Reopen the 3D view to see a change.")
                }

                Section {
                    Picker("Default ceiling height", selection: $defaultCeiling) {
                        ForEach(ceilingChoices, id: \.self) { meters in
                            Text(Measure.length(meters, imperial: useImperial)).tag(meters)
                        }
                    }
                } header: {
                    Text("Capture")
                } footer: {
                    Text("New rooms from corner capture, blueprint tracing, and typed measurements start at this height. LiDAR scans always use the measured height.")
                }

                Section("Business") {
                    Button {
                        showingBusinessProfile = true
                    } label: {
                        Label("Business Profile", systemImage: "building.2")
                    }
                    NavigationLink {
                        PriceBookScreen()
                    } label: {
                        Label("Price Book", systemImage: "dollarsign.circle")
                    }
                    NavigationLink {
                        FixtureAssemblyScreen()
                    } label: {
                        Label("Saved Fixture Assemblies", systemImage: "square.grid.2x2")
                    }
                }

                Section {
                    LabeledContent("Version",
                                   value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0")
                    Link(destination: URL(string: "https://dwyjac-pixel.github.io/interior-ai-reno-planner/privacy.html")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    Link(destination: URL(string: "https://caribinalcreations.ca")!) {
                        Label("Support", systemImage: "questionmark.circle")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Interior AI Reno Planner: scan, plan, price, and permit basement suites from one phone.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingBusinessProfile) {
                BusinessProfileScreen()
            }
        }
    }

    /// The picker needs a concrete colour even when the setting is unset —
    /// fall back to the 3D builder's built-in warm white.
    private var wallColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(hexString: wall3DHex) ?? Color(red: 0.93, green: 0.92, blue: 0.90)
            },
            set: { wall3DHex = $0.hexString() }
        )
    }
}
