import SwiftUI
import UsageKit

/// Prompts for a new account name while `account` is non-nil.
private struct RenameAccountAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var account: AccountConfig?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Account", isPresented: Binding(
                get: { account != nil },
                set: { if !$0 { account = nil } }
            )) {
                TextField("Name", text: $name)
                Button("Rename", action: commit)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Shown in the menu and in notifications.")
            }
            .onChange(of: account?.id) { name = account?.name ?? "" }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var updated = account, !trimmed.isEmpty, trimmed != updated.name else { return }
        updated.name = trimmed
        model.update(updated)
    }
}

extension View {
    func renameAccountAlert(_ account: Binding<AccountConfig?>) -> some View {
        modifier(RenameAccountAlert(account: account))
    }
}
