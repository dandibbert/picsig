import SwiftUI
import PicSigCore

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var newAllowTerm = ""
    @State private var newDenyTerm = ""
    @State private var editedRule: CustomSensitiveRule?
    @State private var isResetConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Form {
                workflowSection
                detectionSection
                categorySection
                listSection(title: "settings.allowList",
                            footnote: "settings.allowList.hint",
                            terms: Binding(get: { settings.scan.allowList },
                                           set: { settings.scan.allowList = $0 }),
                            draft: $newAllowTerm)
                listSection(title: "settings.denyList",
                            footnote: "settings.denyList.hint",
                            terms: Binding(get: { settings.scan.denyList },
                                           set: { settings.scan.denyList = $0 }),
                            draft: $newDenyTerm)
                customRuleSection
                watermarkSection
                aboutSection
            }
            .navigationTitle("settings.title")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done") { dismiss() }
                }
            }
            .sheet(item: $editedRule) { rule in
                CustomRuleEditor(rule: rule) { saved in
                    upsert(saved)
                }
            }
            .confirmationDialog("settings.reset.confirm",
                                isPresented: $isResetConfirmationPresented,
                                titleVisibility: .visible) {
                Button("settings.reset", role: .destructive) { settings.resetToDefaults() }
                Button("common.cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Workflow

    private var workflowSection: some View {
        Section {
            Toggle("settings.scanOnImport", isOn: Binding(get: { settings.scansOnImport },
                                                          set: { settings.scansOnImport = $0 }))
            Toggle("settings.verifyBeforeExport", isOn: Binding(get: { settings.verifiesBeforeExport },
                                                                set: { settings.verifiesBeforeExport = $0 }))
        } header: {
            Text("settings.section.workflow")
        } footer: {
            Text("settings.verifyBeforeExport.hint")
        }
    }

    // MARK: - Detection

    private var detectionSection: some View {
        Section {
            Toggle("settings.detectFaces", isOn: Binding(get: { settings.detectsFaces },
                                                         set: { settings.detectsFaces = $0 }))
            Toggle("settings.detectBarcodes", isOn: Binding(get: { settings.detectsBarcodes },
                                                            set: { settings.detectsBarcodes = $0 }))
            Toggle("settings.useContext", isOn: Binding(get: { settings.scan.useContext },
                                                        set: { settings.scan.useContext = $0 }))
            Toggle("settings.propagate", isOn: Binding(get: { settings.scan.propagateRepeatedValues },
                                                       set: { settings.scan.propagateRepeatedValues = $0 }))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("settings.minConfidence")
                    Spacer()
                    Text(String(format: "%.0f%%", settings.scan.minConfidence * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { settings.scan.minConfidence },
                                      set: { settings.scan.minConfidence = $0 }),
                       in: 0.3...0.9,
                       step: 0.05)
            }
        } header: {
            Text("settings.section.detection")
        } footer: {
            Text("settings.section.detection.hint")
        }
    }

    // MARK: - Categories

    private var categorySection: some View {
        Section {
            ForEach(SensitiveCategory.allCases, id: \.self) { category in
                Toggle(isOn: categoryBinding(category)) {
                    HStack(spacing: 8) {
                        SeverityDot(severity: category.severity)
                        Text(LocalizedStringKey(category.localizationKey))
                        if category.isVisual {
                            Image(systemName: "eye")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        } header: {
            Text("settings.section.categories")
        }
    }

    private func categoryBinding(_ category: SensitiveCategory) -> Binding<Bool> {
        Binding(get: { settings.scan.enabledCategories.contains(category) },
                set: { isOn in
                    if isOn {
                        settings.scan.enabledCategories.insert(category)
                    } else {
                        settings.scan.enabledCategories.remove(category)
                    }
                })
    }

    // MARK: - Allow / deny lists

    private func listSection(title: LocalizedStringKey,
                             footnote: LocalizedStringKey,
                             terms: Binding<[String]>,
                             draft: Binding<String>) -> some View {
        Section {
            ForEach(Array(terms.wrappedValue.enumerated()), id: \.offset) { index, term in
                Text(term)
                    .swipeActions {
                        Button(role: .destructive) {
                            var copy = terms.wrappedValue
                            copy.remove(at: index)
                            terms.wrappedValue = copy
                        } label: {
                            Label("common.delete", systemImage: "trash")
                        }
                    }
            }
            HStack {
                TextField("settings.list.placeholder", text: draft)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    let trimmed = draft.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    terms.wrappedValue.append(trimmed)
                    draft.wrappedValue = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footnote)
        }
    }

    // MARK: - Custom rules

    private var customRuleSection: some View {
        Section {
            ForEach(settings.scan.customRules) { rule in
                Button {
                    editedRule = rule
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name)
                                .foregroundStyle(Color.primary)
                            Text(rule.pattern)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if !rule.isEnabled {
                            Image(systemName: "pause.circle")
                                .foregroundStyle(.tertiary)
                        }
                        if rule.patternError != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        settings.scan.customRules.removeAll { $0.id == rule.id }
                    } label: {
                        Label("common.delete", systemImage: "trash")
                    }
                }
            }

            Button {
                editedRule = CustomSensitiveRule(name: NSLocalizedString("settings.rule.newName", comment: ""),
                                                pattern: "")
            } label: {
                Label("settings.rule.add", systemImage: "plus")
            }
        } header: {
            Text("settings.section.customRules")
        } footer: {
            Text("settings.section.customRules.hint")
        }
    }

    private func upsert(_ rule: CustomSensitiveRule) {
        var rules = settings.scan.customRules
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        settings.scan.customRules = rules
    }

    // MARK: - Watermark

    private var watermarkSection: some View {
        Section {
            Toggle("settings.watermark.enabled", isOn: Binding(get: { settings.isWatermarkEnabled },
                                                               set: { settings.isWatermarkEnabled = $0 }))
            if settings.isWatermarkEnabled {
                TextField("adjust.watermark.placeholder",
                          text: Binding(get: { settings.watermarkText },
                                        set: { settings.watermarkText = $0 }))
            }
        } header: {
            Text("settings.section.watermark")
        } footer: {
            Text("settings.watermark.hint")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("settings.version")
                Spacer()
                Text(Bundle.main.shortVersion)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                isResetConfirmationPresented = true
            } label: {
                Text("settings.reset")
            }
        } header: {
            Text("settings.section.about")
        } footer: {
            Text("settings.privacy")
        }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
