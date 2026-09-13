import SwiftUI
import PicSigCore

/// Editor for a user supplied detection rule, with a live test field.
///
/// Typing a regular expression blind is a good way to mask nothing at all, so the
/// editor scans a sample string as you type and shows exactly what would be hit.
struct CustomRuleEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CustomSensitiveRule
    @State private var sample: String
    let onSave: (CustomSensitiveRule) -> Void

    init(rule: CustomSensitiveRule, onSave: @escaping (CustomSensitiveRule) -> Void) {
        _draft = State(initialValue: rule)
        _sample = State(initialValue: "")
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("settings.rule.name", text: $draft.name)
                    Toggle("settings.rule.enabled", isOn: $draft.isEnabled)
                }

                Section {
                    Toggle("settings.rule.literal", isOn: $draft.isLiteral)
                    TextField(draft.isLiteral ? "settings.rule.text" : "settings.rule.pattern",
                              text: $draft.pattern,
                              axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if let error = draft.patternError {
                        NoticeRow(level: .problem, text: error)
                    }
                } header: {
                    Text("settings.rule.section.pattern")
                } footer: {
                    Text(draft.isLiteral ? "settings.rule.text.hint" : "settings.rule.pattern.hint")
                }

                Section {
                    Picker("settings.rule.category", selection: $draft.category) {
                        ForEach(SensitiveCategory.allCases, id: \.self) { category in
                            Text(LocalizedStringKey(category.localizationKey)).tag(category)
                        }
                    }
                } footer: {
                    Text("settings.rule.category.hint")
                }

                Section {
                    TextField("settings.rule.sample", text: $sample, axis: .vertical)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !sample.isEmpty {
                        if testMatches.isEmpty {
                            Text("settings.rule.noMatch")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(testMatches) { match in
                                HStack {
                                    Text(match.value)
                                        .font(.caption.monospaced())
                                    Spacer()
                                    Text(LocalizedStringKey(match.category.localizationKey))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("settings.rule.section.test")
                }
            }
            .navigationTitle("settings.rule.title")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.save") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.pattern.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.patternError == nil
    }

    /// Only the rule being edited runs, so the preview shows its own hits rather
    /// than everything the built-in catalogue would also find.
    private var testMatches: [SensitiveMatch] {
        guard isValid else { return [] }
        var settings = ScanSettings(enabledCategories: [draft.category],
                                    minConfidence: 0.1,
                                    customRules: [draft])
        settings.enabledRuleIDs = [draft.rule.id]
        let scanner = SensitiveScanner(settings: settings)
        return scanner.scan(text: sample).filter { $0.ruleID.hasPrefix("custom.") }
    }
}
