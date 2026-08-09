import SwiftUI
import SwiftData

struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var clientName = ""
    @State private var address = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var projectType = "Basement Development"

    private let projectTypes = RenovationProject.projectTypes

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Project name (required)", text: $name)
                    Picker("Type", selection: $projectType) {
                        ForEach(projectTypes, id: \.self) { Text($0) }
                    }
                }
                Section("Client") {
                    TextField("Client name", text: $clientName)
                    TextField("Property address", text: $address)
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let project = RenovationProject(
                            name: name.trimmingCharacters(in: .whitespaces),
                            clientName: clientName,
                            address: address,
                            phone: phone,
                            email: email,
                            projectType: projectType
                        )
                        modelContext.insert(project)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
