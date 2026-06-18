import SwiftUI

struct ModelPickerSheet: View {
    @Bindable var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var options: [ModelOption] = []
    @State private var query = ""
    @State private var loading = true
    @State private var applying: String?

    private var filtered: [ModelOption] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return options }
        return options.filter { $0.label.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    private func isCurrent(_ opt: ModelOption) -> Bool {
        guard let m = model.footer?.model else { return false }
        return m == opt.id || m == opt.label || opt.id.hasSuffix("/\(m)") || opt.id == m
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if options.isEmpty {
                    ContentUnavailableView("No models", systemImage: "cpu", description: Text("Could not load model list from your Mac."))
                } else {
                    List(filtered) { opt in
                        Button {
                            Task { await apply(opt) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(opt.label).font(.body).foregroundStyle(.primary)
                                    if opt.label != opt.id {
                                        Text(opt.id).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if applying == opt.id {
                                    ProgressView()
                                } else if isCurrent(opt) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .disabled(applying != nil)
                    }
                    .searchable(text: $query, prompt: "Search models")
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            options = try await model.loadModels()
        } catch {
            model.lastError = error.localizedDescription
        }
    }

    private func apply(_ opt: ModelOption) async {
        applying = opt.id
        defer { applying = nil }
        await model.switchModel(to: opt.id)
        dismiss()
    }
}