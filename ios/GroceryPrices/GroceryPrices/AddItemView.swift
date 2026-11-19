import SwiftUI

/// Form for a new or existing watchlist item, with a live preview of what it would match.
struct ItemForm: View {
    let editing: WatchItem?
    let existing: [String]
    let onSave: (WatchItem) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("postalCode") private var postal = ""
    @State private var name = ""
    @State private var query = ""
    @State private var per = "kg"
    @State private var include = ""  // empty = use the search term
    @State private var exclude = ""
    @State private var hits: [FlippHit] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var saving = false
    @State private var saveError: String?
    @State private var showExcluded = false
    private let sources: [String: String]  // phrase shown -> its regex, for hand-written entries

    init(editing: WatchItem? = nil, existing: [String], onSave: @escaping (WatchItem) async throws -> Void) {
        self.editing = editing
        self.existing = existing
        self.onSave = onSave
        let include = WatchItem.phrases(of: editing?.match), exclude = WatchItem.phrases(of: editing?.exclude)
        sources = Dictionary((include + exclude).map { ($0.shown, $0.source) }, uniquingKeysWith: { a, _ in a })
        guard let editing else { return }
        _name = State(initialValue: editing.item)
        _query = State(initialValue: editing.query)
        _per = State(initialValue: editing.per ?? "kg")
        _include = State(initialValue: include.map(\.shown).joined(separator: ", "))
        _exclude = State(initialValue: exclude.map(\.shown).joined(separator: ", "))
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// The entry as it would be saved, or nil while required fields are missing.
    private var draft: WatchItem? {
        guard !trimmedQuery.isEmpty,
              let match = WatchItem.pattern(fromPhrases: include.isEmpty ? trimmedQuery : include, keeping: sources)
        else { return nil }
        // The typical size of unsized products is in the old unit, so it's dropped on a unit change.
        return WatchItem(item: editing?.item ?? (trimmedName.isEmpty ? trimmedQuery : trimmedName),
                         query: trimmedQuery, per: per, assume: editing?.per == per ? editing?.assume : nil,
                         match: match, exclude: WatchItem.pattern(fromPhrases: exclude, keeping: sources),
                         folder: editing?.folder)
    }

    private var nameTaken: Bool {
        guard editing == nil, let item = draft?.item else { return false }
        return existing.contains { $0.caseInsensitiveCompare(item) == .orderedSame }
    }

    private var kept: [FlippHit] { draft.map { d in hits.filter { d.matches($0.name) } } ?? [] }
    private var dropped: [FlippHit] { draft.map { d in hits.filter { !d.matches($0.name) } } ?? hits }

    var body: some View {
        NavigationStack {
            Form { Group {
                if let saveError {
                    Section { Label(saveError, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                Section {
                    TextField("Search term, e.g. greek yogurt", text: $query)
                        .autocorrectionDisabled()
                    if let editing {
                        LabeledContent("Name", value: editing.item)
                    } else {
                        TextField("Name in the app (optional)", text: $name, prompt: Text(trimmedQuery.isEmpty ? "Name in the app (optional)" : trimmedQuery))
                    }
                    Picker("Compare", selection: $per) {
                        Text("per kg").tag("kg")
                        Text("per L").tag("L")
                        Text("per dozen").tag("dozen")
                        Text("shelf price").tag("each")
                    }
                } footer: {
                    if nameTaken {
                        Text("You already track an item with this name.").foregroundStyle(.red)
                    } else if editing != nil {
                        Text("Saving re-runs today's collection and recalculates past unit prices. The name can't change because price history is kept by name.")
                    } else {
                        Text("Use “shelf price” for things sold by the package, like bread or cereal.")
                    }
                }

                Section {
                    TextField("Name must contain", text: $include,
                              prompt: Text(trimmedQuery.isEmpty ? "Name must contain" : trimmedQuery))
                        .autocorrectionDisabled()
                    TextField("Exclude if name contains", text: $exclude, prompt: Text("Exclude, e.g. drink, frozen, kids"))
                        .autocorrectionDisabled()
                } header: {
                    Text("Which products count")
                } footer: {
                    Text("Separate phrases with commas. A product is kept if its name contains any “must contain” phrase and none of the “exclude” phrases. Capitals don't matter.")
                }

                previewSections
            }.listRowBackground(Color.card) }
            .paper()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(editing == nil ? "Add item" : "Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(editing == nil ? "Add" : "Save") { Task { await save() } }
                            .disabled(draft == nil || nameTaken || draft == editing)
                    }
                }
            }
            .task(id: trimmedQuery) { await search() }
        }
    }

    @ViewBuilder private var previewSections: some View {
        if postal.isEmpty {
            Section("Preview") {
                Text("Add your postal code in Settings to preview which products this matches.")
                    .foregroundStyle(.secondary)
            }
        } else if trimmedQuery.isEmpty {
            EmptyView()
        } else {
            Section {
                if searching && hits.isEmpty {
                    ProgressView()
                } else if let searchError {
                    Text(searchError).foregroundStyle(.secondary)
                } else if kept.isEmpty {
                    Text("Nothing at your stores matches right now.").foregroundStyle(.secondary)
                }
                ForEach(kept) { HitRow(hit: $0) }
            } header: {
                Text("Matches today (\(kept.count))")
            } footer: {
                Text("Flyer items only appear in weeks they're on sale. Unit prices are worked out after the first collection.")
            }
            if !dropped.isEmpty {
                Section {
                    DisclosureGroup("Left out (\(dropped.count))", isExpanded: $showExcluded) {
                        ForEach(dropped) { HitRow(hit: $0).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func search() async {
        guard !postal.isEmpty, !trimmedQuery.isEmpty else { hits = []; return }
        try? await Task.sleep(for: .milliseconds(500))  // wait for typing to pause
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            hits = try await FlippSearch.search(trimmedQuery, postal: postal)
            searchError = nil
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { searchError = "Couldn't reach Flipp for a preview. You can still add the item." }
        }
    }

    private func save() async {
        guard let draft else { return }
        saving = true
        defer { saving = false }
        do {
            try await onSave(draft)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

private struct HitRow: View {
    let hit: FlippHit

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.store).font(.subheadline.weight(.semibold))
                Text(hit.name).font(.caption).foregroundStyle(Color.inkSoft).lineLimit(2)
            }
            Spacer()
            Text(hit.price.formatted(.currency(code: "CAD")) + (hit.unit.isEmpty ? "" : " \(hit.unit)"))
                .font(.label(.caption))
        }
    }
}

/// GitHub token and postal code.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("postalCode") private var postal = ""
    @State private var token = ""
    @State private var hasToken = Keychain.token != nil

    var body: some View {
        NavigationStack {
            Form { Group {
                Section {
                    if hasToken {
                        LabeledContent("Token", value: "Saved")
                        Button("Remove token", role: .destructive) {
                            Keychain.token = nil
                            hasToken = false
                        }
                    } else {
                        SecureField("Paste token", text: $token)
                        Button("Save token") {
                            Keychain.token = token
                            token = ""
                            hasToken = Keychain.token != nil
                        }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Link("Create a token on GitHub",
                         destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                } header: {
                    Text("GitHub token")
                } footer: {
                    Text("Needed to add or remove items. Create a fine-grained token with access to only the grocery-scraper repository and these permissions: Contents: Read and write, and Actions: Read and write. It's stored in this phone's Keychain.")
                }

                Section {
                    TextField("A1A 1A1", text: $postal)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("Postal code")
                } footer: {
                    Text("Used on this phone only, to find flyers near you and to preview matches while you add an item. The daily collection uses the postal code saved in GitHub.")
                }
            }.listRowBackground(Color.card) }
            .paper()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
