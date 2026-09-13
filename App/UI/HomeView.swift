import Foundation
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var settings = false
    @State private var pickerPresented = false
    @State private var pickerLoading = false
    @State private var pendingKind: ProjectKind = .scroll

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    VStack(alignment: .leading, spacing: 10) {
                        Text("长截图").font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("选截图，自动拼。失败的拼接点再手动调。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    Button { pick(.scroll) } label: {
                        HStack(spacing: 16) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 18).fill(Color.picAccent.opacity(0.13))
                                Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 31, weight: .semibold)).foregroundStyle(Color.picAccent)
                            }.frame(width: 64, height: 64)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("选择截图并自动拼接").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                                Text("自动识别重叠，并清理重复的状态栏 / 地址栏 / 工具栏")
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(18)
                        .background(.background, in: RoundedRectangle(cornerRadius: 24))
                        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.picAccent.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("quick-scroll")

                    VStack(alignment: .leading, spacing: 12) {
                        Text("其他方式").font(.headline)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            quickCard(title: "录屏转长图", subtitle: "导入系统录屏", symbol: "record.circle", color: .red) {
                                library.create(.video)
                            }
                            quickCard(title: "竖向拼图", subtitle: "照片上下排列", symbol: "rectangle.split.1x2", color: .orange) {
                                pick(.vertical)
                            }
                            quickCard(title: "横向拼图", subtitle: "并排比较", symbol: "rectangle.split.2x1", color: .blue) {
                                pick(.horizontal)
                            }
                            quickCard(title: "隐私规则", subtitle: "地址也默认识别", symbol: "checkmark.shield", color: .picMint) {
                                settings = true
                            }
                        }
                    }

                    if let recent = library.projects.first {
                        Button { library.open(recent) } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(Color.picAccent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("继续上次编辑").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text("\(recent.updatedAt.formatted(.relative(presentation: .named))) · 自动保存")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }.padding(15).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("resume-recent")
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield").foregroundStyle(Color.picMint)
                        Text("拼接、OCR 和隐私识别都在本机完成。自动打码仍需在导出前复核。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Color.picCanvas)
            .toolbar(.hidden, for: .navigationBar)
        }
        .fullScreenCover(item: $library.active, onDismiss: { Task { await library.reload() } }) { session in
            StudioView(session: session)
        }
        .sheet(isPresented: $pickerPresented) {
            MediaPicker(video: false, limit: 60, started: { pickerLoading = true }) { result in
                pickerLoading = false
                let kind = pendingKind
                pickerPresented = false
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        library.beginQuick(urls, kind: kind)
                    }
                case .failure(let error):
                    library.notice = Notice(title: "导入失败", message: error.localizedDescription)
                }
            }
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                PrivacySettingsView(options: $library.defaults, defaults: true)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { Task { await library.saveDefaults(); settings = false } }
                        }
                    }
            }
        }
        .overlay {
            if pickerLoading {
                ProgressView("正在读取所选图片…")
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .notice($library.notice)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.picAccent)
                Text("PicSig").font(.system(size: 23, weight: .bold, design: .rounded))
            }
            Spacer()
            Button { settings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3).frame(width: 44, height: 44)
                    .background(.background, in: Circle())
            }
            .accessibilityLabel("设置")
        }
    }

    private func quickCard(title: String, subtitle: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 13) {
                Image(systemName: symbol).font(.system(size: 23, weight: .medium)).foregroundStyle(color)
                    .frame(width: 45, height: 45).background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
            .padding(15)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(title == "录屏转长图" ? "create-video" : title == "竖向拼图" ? "quick-vertical" : title == "横向拼图" ? "quick-horizontal" : "privacy-settings")
    }

    private func pick(_ kind: ProjectKind) {
        pendingKind = kind
        pickerPresented = true
    }
}

@MainActor
extension LibraryModel {
    func beginQuick(_ urls: [URL], kind: ProjectKind) {
        guard !urls.isEmpty else { return }
        var draft = Project(title: kind == .scroll ? "长截图" : kind.title, kind: kind)
        draft.privacy = defaults
        let session = StudioSession(project: draft)
        active = session
        session.quickImport(urls, finishInEditor: kind == .scroll)
    }
}

@MainActor
extension StudioSession {
    func quickImport(_ urls: [URL], finishInEditor: Bool) {
        importImages(urls)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.waitForQuickWork()
            guard !Task.isCancelled, !self.project.images.isEmpty else { return }

            if self.project.kind.isScroll, self.project.images.count > 1 {
                self.autoStitch(trimBars: true)
                await self.waitForQuickWork()
                guard !Task.isCancelled else { return }
                self.cleanDetectedOuterBars()
            }

            if finishInEditor {
                self.enterEditor()
            }
        }
    }

    private func waitForQuickWork() async {
        while busy && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    /// Manual stitching keeps the first header and final footer so a user never loses content silently.
    /// Quick long-screenshot mode removes those outer copies once the same fixed strip has been detected
    /// on adjacent screenshots. Preserve the overlap in *pixels* when the last crop gets shorter.
    private func cleanDetectedOuterBars() {
        guard project.images.count >= 2 else { return }
        let images = project.images
        let referenceHeight = median(images.map(\.size.height))

        let topCandidates = images.dropFirst().compactMap { source -> Double? in
            guard let automatic = source.automaticCrop else { return nil }
            let pixels = max(0, (automatic.y - source.crop.y) * source.size.height)
            return pixels >= 8 && pixels <= referenceHeight * 0.22 ? pixels : nil
        }
        let bottomCandidates = images.dropLast().compactMap { source -> Double? in
            guard let automatic = source.automaticCrop else { return nil }
            let pixels = max(0, (source.crop.maxY - automatic.maxY) * source.size.height)
            return pixels >= 8 && pixels <= referenceHeight * 0.22 ? pixels : nil
        }
        let topPixels = median(topCandidates)
        let bottomPixels = median(bottomCandidates)
        guard topPixels > 0 || bottomPixels > 0 else {
            note = "已自动拼接。若某个拼接点不准，点左上角「拼接」逐处微调。"
            return
        }

        change { project in
            if topPixels > 0, !project.images.isEmpty {
                var source = project.images[0]
                let current = source.automaticCrop ?? source.crop
                let y = max(current.y, source.crop.y + topPixels / max(1, source.size.height))
                if current.maxY - y > 0.01 {
                    source.automaticCrop = Box(current.x, y, current.width, current.maxY - y).intersection(.unit)
                    project.images[0] = source
                }
            }
            if bottomPixels > 0, !project.images.isEmpty {
                let index = project.images.count - 1
                var source = project.images[index]
                let current = source.automaticCrop ?? source.crop
                let maxY = min(current.maxY, source.crop.maxY - bottomPixels / max(1, source.size.height))
                if maxY - current.y > 0.01 {
                    let newCrop = Box(current.x, current.y, current.width, maxY - current.y).intersection(.unit)
                    let overlapPixels = source.leadingCut * current.height * source.size.height
                    source.automaticCrop = newCrop
                    source.leadingCut = min(0.95, overlapPixels / max(1, newCrop.height * source.size.height))
                    project.images[index] = source
                }
            }
        }
        refreshPreview()
        note = "已自动拼接，并清理检测到的固定状态栏 / 地址栏 / 工具栏。需要时可返回「拼接」微调。"
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) { return (sorted[middle - 1] + sorted[middle]) / 2 }
        return sorted[middle]
    }
}
