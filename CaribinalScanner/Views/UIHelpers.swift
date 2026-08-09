import SwiftUI
import UIKit

extension View {
    /// Adds a Done button above the numeric keyboard — which otherwise has
    /// no return key, leaving users stuck with the keyboard covering the
    /// screen. Apply once per screen that contains numeric fields.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
                .fontWeight(.semibold)
            }
        }
    }
}

/// A small ⓘ that explains an investing term in one sentence — for the
/// realtors and newer investors the analyzer is meant to welcome.
struct InfoButton: View {
    let title: String
    let message: String
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .accessibilityHint("Shows a one-line explanation")
        .alert(title, isPresented: $showing) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
