import SwiftUI
import UIKit
import PicSigCore

/// Review and tune the masking.
///
/// One pass reads the whole image; everything it found is listed with a checkbox,
/// and the user decides what stays masked. The two hand tools — tap a line of text,
/// or draw a box — sit next to the scan button because they are the fallback for
/// whatever the scan did not catch. Presets and per-category rules are still
/// there, but under "advanced": they are defaults, not the workflow.
struct RedactionPanel: View {
    let model: WorkbenchViewModel

    @State private var styleEditingCategory: SensitiveCategory?
    @State private var isAdvancedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            primaryRow
            summaryRow
            if model.needsRescan { rescanNotice }
            if !model.matches.isEmpty { foundSection }
            manualItemsSection
            verificationSection
            advancedSection
        }
    }

    // MARK: - Primary actions

    private var primaryRow: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.scanForSensitiveInformation() }
            } label: {
                Label(model.hasScannedOnce ? "redact.rescan" : "redact.scan",
                      systemImage: "sparkle.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(model.isScanning || model.isBusy)

            ChipButton(title: "redact.pickText",
                       systemImage: "text.viewfinder",
                       isSelected: model.activeTool == .textPick) {
                Task { await model.startTextPicking() }
            }
            ChipButton(title: "redact.drawBox",
                       systemImage: "rectangle.dashed",
                       isSelected: model.activeTool == .redactionBox) {
                model.activeTool = model.activeTool == .redactionBox ? .none : .redactionBox
            }
            Spacer(minLength: 0)
            styleMenu
        }
        .padding(.top, 2)
    }

    /// Default mask style, applied to hand drawn and tapped areas and offered as the
    /// bulk choice for everything found.
    private var styleMenu: some View {
        Menu {
            ForEach(RedactionStyle.allCases, id: \.self) { style in
                Button {
                    model.setDefaultMaskingStyle(style)
                    model.setStyleForAllCategories(style)
                } label: {
                    Label(LocalizedStringKey(style.localizationKey),
                          systemImage: model.defaultMaskingStyle == style ? "checkmark" : "circle")
                }
            }
        } label: {
            ChipLabel(title: LocalizedStringKey(model.defaultMaskingStyle.localizationKey),
                      systemImage: "paintbrush")
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            if model.hasScannedOnce {
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("redact.notScanned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.matches.isEmpty {
                Button("redact.enableAll") { model.enableAllMatches(true) }
                Button("redact.disableAll") { model.enableAllMatches(false) }
                Toggle(isOn: Binding(get: { model.highlightsMatches },
                                     set: { model.highlightsMatches = $0 })) {
                    Image(systemName: "eye")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .accessibilityLabel("redact.highlight")
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }

    private var summaryText: String {
        if model.matches.isEmpty {
            return NSLocalizedString("redact.nothingFound", comment: "")
        }
        return String(format: NSLocalizedString("redact.summary.format", comment: "enabled, total"),
                      model.enabledMatchCount,
                      model.matches.count)
    }

    private var rescanNotice: some View {
        NoticeRow(level: .warning, text: NSLocalizedString("redact.staleResults", comment: ""))
    }

    // MARK: - Found

    private var foundSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.matchesByCategory, id: \.category) { group in
                CategoryRow(model: model,
                            category: group.category,
                            matches: group.matches,
                            isEditingStyle: styleEditingCategory == group.category) {
                    withAnimation(.snappy) {
                        styleEditingCategory = styleEditingCategory == group.category ? nil : group.category
                    }
                }
            }
            Text("redact.tapHint")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Hand drawn / tapped

    @ViewBuilder
    private var manualItemsSection: some View {
        let manualItems = model.document.state.redactions.filter(\.isManual)
        if !manualItems.isEmpty {
            PanelSection(title: "redact.section.manual") {
                ForEach(manualItems) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.sourceLineID == nil ? "rectangle.dashed" : "text.viewfinder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(LocalizedStringKey(item.style.localizationKey))
                            .font(.caption)
                        Spacer()
                        Button {
                            model.removeRedaction(item.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $isAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("redact.preset.hint")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RedactionPreset.all) { preset in
                            ChipButton(title: LocalizedStringKey(preset.titleKey),
                                       systemImage: preset.symbolName,
                                       isSelected: model.activePresetID == preset.id) {
                                model.apply(preset: preset)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("redact.section.advanced")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: - Verification

    private var verificationSection: some View {
        PanelSection(title: "redact.section.verify",
                     footnote: "redact.verify.hint") {
            Button {
                Task { await model.verifyRedaction() }
            } label: {
                Label("redact.verifyNow", systemImage: "checkmark.shield")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.document.state.redactions.isEmpty)

            if let audit = model.audit {
                AuditReport(audit: audit)
            }
        }
    }
}

// MARK: - Category row

/// One group of findings: the category, a bulk toggle, every value with its own
/// checkbox, and — on request — how that category is masked.
private struct CategoryRow: View {
    let model: WorkbenchViewModel
    let category: SensitiveCategory
    let matches: [SensitiveMatch]
    let isEditingStyle: Bool
    let toggleStyleEditing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isEditingStyle {
                styleControls
            }
            matchList
        }
        .padding(10)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 8) {
            SeverityDot(severity: category.severity)
            Text(LocalizedStringKey(category.localizationKey))
                .font(.subheadline.weight(.medium))
            Text("\(matches.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: toggleStyleEditing) {
                Label(LocalizedStringKey(model.rule(for: category).style.localizationKey),
                      systemImage: "paintbrush")
                    .font(.caption2)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(isEditingStyle ? .accentColor : .secondary)
            Toggle("", isOn: Binding(get: { model.isCategoryFullyEnabled(category) },
                                     set: { model.setCategory(category, enabled: $0) }))
                .labelsHidden()
                .controlSize(.mini)
        }
    }

    @ViewBuilder
    private var styleControls: some View {
        let rule = model.rule(for: category)

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(RedactionStyle.allCases, id: \.self) { style in
                    ChipButton(title: LocalizedStringKey(style.localizationKey),
                               isSelected: rule.style == style) {
                        model.setStyle(style, for: category)
                    }
                }
            }
            .padding(.vertical, 1)
        }

        if rule.style == .blur {
            NoticeRow(level: .warning, text: NSLocalizedString("redact.blurWarning", comment: ""))
        }

        if rule.style != .replacement {
            SliderRow(title: "redact.strength",
                      value: Binding(get: { rule.strength },
                                     set: { model.setStrength($0, for: category) }),
                      range: 0.2...1,
                      step: 0.05,
                      display: { String(format: "%.0f%%", $0 * 100) })
        }

        if !category.isVisual, rule.style != .replacement {
            HStack(spacing: 12) {
                Stepper(value: Binding(get: { rule.preserveLeading },
                                       set: { model.setPreserved(leading: $0, for: category) }),
                        in: 0...8) {
                    Text(String(format: NSLocalizedString("redact.preserveLeading.format", comment: ""),
                                rule.preserveLeading))
                        .font(.caption)
                }
                Stepper(value: Binding(get: { rule.preserveTrailing },
                                       set: { model.setPreserved(trailing: $0, for: category) }),
                        in: 0...8) {
                    Text(String(format: NSLocalizedString("redact.preserveTrailing.format", comment: ""),
                                rule.preserveTrailing))
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var matchList: some View {
        Divider()
        ForEach(matches) { match in
            HStack(spacing: 8) {
                Button {
                    model.setMatch(match.id, enabled: !match.isEnabled)
                } label: {
                    Image(systemName: match.isEnabled ? "checkmark.square.fill" : "square")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                VStack(alignment: .leading, spacing: 1) {
                    Text(RedactionPlanner.preview(of: match.value))
                        .font(.caption.monospaced())
                        .foregroundStyle(match.isEnabled ? Color.primary : Color.secondary)
                    if let label = match.contextLabel {
                        Text(String(format: NSLocalizedString("redact.context.format", comment: ""), label))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Text("\(Int((match.confidence * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Audit

/// What was masked and, more importantly, what was not.
private struct AuditReport: View {
    let audit: RedactionAudit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: audit.isClean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(audit.isClean ? .green : .orange)
                Text(headline)
                    .font(.caption.weight(.semibold))
            }

            ForEach(audit.entries) { entry in
                HStack(spacing: 6) {
                    SeverityDot(severity: entry.category.severity)
                    Text(LocalizedStringKey(entry.category.localizationKey))
                        .font(.caption2)
                    Spacer()
                    Text(entry.styles.map { NSLocalizedString($0.localizationKey, comment: "") }
                        .joined(separator: " / "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("×\(entry.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if audit.potentiallyReversibleCount > 0 {
                NoticeRow(level: .warning,
                          text: String(format: NSLocalizedString("redact.audit.reversible", comment: ""),
                                       audit.potentiallyReversibleCount))
            }

            ForEach(audit.coverageIssues) { issue in
                NoticeRow(level: .warning,
                          text: String(format: NSLocalizedString("redact.audit.coverage", comment: ""),
                                       NSLocalizedString(issue.category.localizationKey, comment: ""),
                                       Int((issue.coveredFraction * 100).rounded())))
            }

            ForEach(audit.residualLeaks) { leak in
                NoticeRow(level: .problem,
                          text: String(format: NSLocalizedString(leakKey(leak.reason), comment: ""),
                                       NSLocalizedString(leak.category.localizationKey, comment: ""),
                                       leak.valuePreview))
            }
        }
        .padding(10)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }

    private var headline: String {
        if !audit.wasVerified {
            return String(format: NSLocalizedString("redact.audit.planned", comment: ""), audit.itemCount)
        }
        return audit.isClean
            ? String(format: NSLocalizedString("redact.audit.clean", comment: ""), audit.itemCount)
            : NSLocalizedString("redact.audit.dirty", comment: "")
    }

    private func leakKey(_ reason: ResidualLeak.Reason) -> String {
        switch reason {
        case .valueStillReadable: return "redact.audit.leak.readable"
        case .textInsideMaskedArea: return "redact.audit.leak.inside"
        }
    }
}
