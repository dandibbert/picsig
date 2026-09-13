import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVKit

struct MediaPicker: UIViewControllerRepresentable {
    var video = false
    var limit = 60
    var started: () -> Void = {}
    var completion: (Result<[URL], Error>) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = video ? .videos : .images
        configuration.selectionLimit = video ? 1 : max(1, limit)
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration); picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MediaPicker
        init(_ parent: MediaPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { parent.completion(.success([])); return }
            parent.started()
            Task { @MainActor in
                var urls: [URL] = []
                do {
                    for result in results {
                        let type = parent.video ? UTType.movie.identifier : UTType.image.identifier
                        let url: URL = try await withCheckedThrowingContinuation { continuation in
                            result.itemProvider.loadFileRepresentation(forTypeIdentifier: type) { file, error in
                                guard let file = file else { continuation.resume(throwing: error ?? PicSigError.invalidImage); return }
                                do {
                                    let directory = ProjectStore.root.appendingPathComponent("Imports", isDirectory: true)
                                    try ProjectStore.prepare(directory)
                                    let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(file.pathExtension)
                                    // Copy inside the provider callback: its URL expires when this closure returns.
                                    try FileManager.default.copyItem(at: file, to: destination)
                                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
                                    continuation.resume(returning: destination)
                                } catch { continuation.resume(throwing: error) }
                            }
                        }
                        urls.append(url)
                    }
                    parent.completion(.success(urls))
                } catch { ProjectStore.discardImports(urls); parent.completion(.failure(error)) }
            }
        }
    }
}

struct VideoSelection: Identifiable { let id = UUID(); let url: URL }
struct VideoImportView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    var begin: (VideoOptions) -> Void
    @State private var didBegin = false
    @State private var duration = 0.0
    @State private var options = VideoOptions()
    @State private var player: AVPlayer?
    @State private var notice: Notice?
    var body: some View {
        NavigationStack {
            Form {
                if let player = player { VideoPlayer(player: player).frame(height: 210).listRowInsets(EdgeInsets()) }
                Section("选择要转换的范围") {
                    if duration > 0 {
                        Text("录屏时长 \(time(duration)) · 本次 \(time(options.end - options.start))").font(.subheadline.monospacedDigit())
                        VStack(alignment: .leading) {
                            Text("开始 \(time(options.start))").font(.caption)
                            Slider(value: Binding(get: { options.start }, set: { value in
                                options.start = value; options.end = min(duration, max(value + 0.1, min(options.end, value + 120)))
                                player?.seek(to: CMTime(seconds: value, preferredTimescale: 600))
                            }), in: 0...max(0.01, duration - 0.1))
                        }
                        VStack(alignment: .leading) {
                            Text("结束 \(time(options.end))").font(.caption)
                            Slider(value: $options.end, in: min(duration, options.start + 0.05)...max(min(duration, options.start + 0.05), min(duration, options.start + 120)))
                        }
                    } else { ProgressView("正在读取录屏…") }
                }
                Section("画面提取") {
                    Picker("采样频率", selection: $options.interval) {
                        Text("精细 · 每秒 4 帧").tag(0.25)
                        Text("均衡 · 每秒 2 帧").tag(0.5)
                        Text("慢速滚动 · 每秒 1 帧").tag(1.0)
                    }
                    Toggle("录屏是从下向上滚动的", isOn: $options.reverse)
                }
                Section {
                    Label("先用系统录屏保存视频，再导入这里。", systemImage: "record.circle")
                    Text("每次处理最长 120 秒、最多 120 个有效画面。请尽量匀速、单向滚动，避免弹窗、快速跳页或反复回滚。复杂画面需在下一步校正拼接缝。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button { player?.pause(); didBegin = true; begin(options); dismiss() } label: { Text("提取并拼成长图").frame(maxWidth: .infinity).fontWeight(.semibold) }
                        .disabled(duration <= 0 || options.end <= options.start).accessibilityIdentifier("convert-video")
                }
            }.navigationTitle("录屏转长图").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .task {
                    do {
                        _ = url.startAccessingSecurityScopedResource()
                        duration = try await MediaWorker.shared.videoDuration(url)
                        options.end = min(duration, 30); player = AVPlayer(url: url)
                    } catch { notice = Notice(title: "无法打开录屏", message: error.localizedDescription) }
                }
                .onDisappear { player?.pause(); player = nil; url.stopAccessingSecurityScopedResource(); if !didBegin { ProjectStore.discardImports([url]) } }
                .notice($notice)
        }
    }
    private func time(_ value: Double) -> String { String(format: "%02d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60)) }
}
