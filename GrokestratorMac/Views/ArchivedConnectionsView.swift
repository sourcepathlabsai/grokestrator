import SwiftUI
import GrokestratorCore

/// Sheet listing archived Connections, with Restore (un-archive) and Delete
/// Permanently. Delete Permanently is the only destructive action in the
/// Connection lifecycle and is gated by a confirmation alert.
struct ArchivedConnectionsView: View {
    @Bindable var model: GrokestratorModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: ManagedConnection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Archived Connections")
                    .font(Theme.display(16, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            if model.archivedConnections.isEmpty {
                Text("No archived Connections.")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.archivedConnections) { conn in
                        row(conn)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 520, minHeight: 320)
        .background(Theme.bgDeep)
        .alert("Delete \(pendingDelete?.name ?? "Connection") permanently?",
               isPresented: deleteAlertBinding,
               presenting: pendingDelete) { conn in
            Button("Delete Permanently", role: .destructive) {
                model.deletePermanently(conn)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This drops the Connection's configuration and full transcript from disk. There is no undo.")
        }
    }

    private func row(_ conn: ManagedConnection) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(conn.name).font(Theme.body(13, .medium)).foregroundStyle(Theme.textBody)
                if let cwd = conn.workingDirectory {
                    Text(cwd).font(Theme.mono(11)).foregroundStyle(Theme.textFaint)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button("Restore") { model.restore(conn) }
            Button("Delete Permanently", role: .destructive) { pendingDelete = conn }
        }
        .padding(.vertical, 4)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }
}
