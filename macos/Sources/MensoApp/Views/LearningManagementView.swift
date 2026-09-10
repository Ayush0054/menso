import MensoCore
import SwiftUI

struct LearningManagementView: View {
    let manager: (any AgentOSLearningManaging)?

    @Environment(\.dismiss) private var dismiss
    @State private var records: [AgentOSLearningRecord] = []
    @State private var drafts: [String: String] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What Menso learned")
                        .font(.title3.bold())
                    Text("Only records owned by your verified AgentOS identity are shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            Group {
                if manager == nil {
                    ContentUnavailableView(
                        "AgentOS is not connected",
                        systemImage: "person.crop.circle.badge.exclamationmark"
                    )
                } else if isLoading && records.isEmpty {
                    ProgressView("Loading learnings…")
                } else if records.isEmpty {
                    ContentUnavailableView(
                        "No user learnings",
                        systemImage: "brain.head.profile",
                        description: Text("Confirmed profile and memory records will appear here.")
                    )
                } else {
                    List(records) { record in
                        LearningRecordEditor(
                            record: record,
                            draft: Binding(
                                get: { drafts[record.id] ?? "{}" },
                                set: { drafts[record.id] = $0 }
                            ),
                            save: { save(record) },
                            delete: { delete(record) }
                        )
                    }
                    .listStyle(.inset)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .task { await reload() }
    }

    @MainActor
    private func reload() async {
        guard let manager else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            records = try await manager.userLearnings()
            drafts = Dictionary(uniqueKeysWithValues: records.map { record in
                (record.id, Self.prettyJSON(record.content ?? [:]))
            })
            errorMessage = nil
        } catch {
            errorMessage = "Learnings could not be loaded from the authenticated account."
        }
    }

    @MainActor
    private func save(_ record: AgentOSLearningRecord) {
        guard let manager,
              let text = drafts[record.id],
              let data = text.data(using: .utf8),
              let content = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              !content.isEmpty
        else {
            errorMessage = "Content must be a non-empty JSON object."
            return
        }
        Task {
            do {
                let updated = try await manager.updateLearning(id: record.id, content: content)
                if let index = records.firstIndex(where: { $0.id == record.id }) {
                    records[index] = updated
                    drafts[record.id] = Self.prettyJSON(updated.content ?? [:])
                }
                errorMessage = nil
            } catch {
                errorMessage = "This learning could not be updated."
            }
        }
    }

    @MainActor
    private func delete(_ record: AgentOSLearningRecord) {
        guard let manager else { return }
        Task {
            do {
                try await manager.deleteLearning(id: record.id)
                records.removeAll { $0.id == record.id }
                drafts.removeValue(forKey: record.id)
                errorMessage = nil
            } catch {
                errorMessage = "This learning could not be deleted."
            }
        }
    }

    private static func prettyJSON(_ content: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(content)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

private struct LearningRecordEditor: View {
    let record: AgentOSLearningRecord
    @Binding var draft: String
    let save: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.learningType.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.headline)
                Spacer()
                Text(record.namespace ?? "user")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $draft)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 100)
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.2))
                }
            HStack {
                Button("Delete", role: .destructive, action: delete)
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 6)
    }
}
