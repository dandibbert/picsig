import SwiftUI
import UIKit
import PicSigCore

/// Review and tune the automatic masking.
///
/// The panel is deliberately built around *review* rather than around a single
/// "blur everything" button: the user sees what was found, why it was found and
/// what the result will look like, and can then verify that the exported image
/// really is clean.
struct RedactionPanel: View {
    let model: WorkbenchViewModel

    @State private var expandedCategory: SensitiveCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            summarySection
            if model.needsRescan { rescanNotice }
            presetSection
            if !model.matches.isEmpty { categorySection }
            manualSection
            verificationSection
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        PanelSection(title: "redact.section.summary") {
            HStack(spacing: 10) {
                if model.hasScannedOnce {
                    Label(summaryText, systemImage: "eye.slash")
                        .font(.subheadline)
                        .labelStyle(.titleAndIcon)
                } else {
                    Text("redact.notScanned")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.scanForSensitiveInformation() }
                } label: {
                    Label(model.hasScannedOnce ? "redact.rescan" : "redact.scan",
                          systemImage: "sparkle.magnifyingglass")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isScanning)
            }

            if !model.matches.isEmpty {
                HStack(spacing: 14) {
                    Toggle("redact.highlight", isOn: Binding(get: { model.highlightsMatches },
                                                             set: { model.highlightsMatches = $0 }))
                        .font(.caption)
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    Button("redact.enableAll") { model.enableAllMatches(true) }
                    Button("redact.disableAll") { model.enableAllMatches(false) }
                }
                .font(.caption)
                .buttonStyle(.borderless)

                Text("redact.tapHint")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if model.hasScannedOnce {
                Text("redact.nothingFound")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summaryText: String {
        String(format: NSLocalizedString("redact.summary.format", comment: "enabled, total"),
               model.enabledMatchCount,
               model.matches.count)
    }

    private var rescanNotice: some View {
        NoticeRow(level: .warning, text: NSLocalizedString("redact.staleResults", comment: ""))
    }

    // MARK: - Presets

    private var presetSection: some View {
        PanelSection(title: "redact.section.preset") {
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
    }

    // MARK: - Categories

    private var categorySection: some View {
        PanelSection(title: "redact.section.found") {
            ForEach(model.matchesByCategory, id: \.category) { group in
                CategoryRow(model: model,
                            category: group.category,
                            matches: group.matches,
                            isExpanded: expandedCategory == group.category) {
                    withAnimation(.snappy) {
                        expandedCategory = expandedCategory == group.category ? nil : group.category
                    }
                }
            }
        }
    }

    // MARK: - Manual masking

    private var manualSection: some View {
        PanelSection(title: "redact.section.manual",
                     footnote: "redact.manual.hint") {
            HStack(spacing: 8) {
                ChipButton(title: "redact.drawBox",
                           systemImage: "rectangle.dashed",
                           isSelected: model.activeTool == .redactionBox) {
                    model.activeTool = model.activeTool == .redactionBox ? .none : .redactionBox
                }
                Menu {
                    ForEach(RedactionStyle.allCases, id: \.self) { style in
                        Button {
                            model.setDefaultMaskingStyle(style)
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

            let manualItems = model.document.state.redactions.filter(\.isManual)
            if !manualItems.isEmpty {
                ForEach(manualItems) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.fill")
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

/// One collapsible group: the category, how many values it matched, and — when
/// opened — exactly how those values are hidden.
private struct CategoryRow: View {
    let model: WorkbenchViewModel
    let category: SensitiveCategory
    let matches: [SensitiveMatch]
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                styleControls
                matchList
            }
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
            Toggle("", isOn: Binding(get: { model.isEnabled(category) },
                                     set: { model.setCategory(category, enabled: $0) }))
                .labelsHidden()
                .controlSize(.mini)
            Button(action: toggleExpanded) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleExpanded)
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
