import SwiftUI

struct PrivacySettingsView: View {
    @Binding var options: PrivacyOptions
    var defaults = false
    @State private var keywords = ""
    @State private var clearCache = false
    @State private var notice: Notice?
    var body: some View {
        Form {
            Section {
                Label("只在本机识别，不上传截图或录屏", systemImage: "lock.shield").font(.subheadline.weight(.medium))
                Text(defaults ? "这些规则用于新建项目，已有项目保持各自设置。" : "修改规则后，返回编辑器点「智能打码」重新识别。现有遮挡不会自动删除。")
                    .font(.footnote).foregroundStyle(.secondary)
                Menu("应用识别预设") {
                    ForEach(["日常分享", "开发日志", "订单票据"], id: \.self) { name in
                        Button(name) { options.enabledKinds = PrivacyOptions.preset(name).enabledKinds }
                    }
                }
            }
            Section("要寻找的敏感信息") {
                ForEach(SensitiveKind.allCases.filter { $0 != .manual }, id: \.self) { kind in
                    Toggle(isOn: Binding(get: { options.enabledKinds.contains(kind) }, set: { enabled in
                        if enabled { options.enabledKinds.insert(kind) } else { options.enabledKinds.remove(kind) }
                    })) { Label(kind.title, systemImage: kind.symbol).font(.subheadline) }
                }
            }
            Section {
                Toggle("整行遮挡（更保守）", isOn: $options.wholeLine)
                Toggle("自动关联相同内容", isOn: $options.linkRepeated)
                HStack { Text("识别框安全扩边"); Spacer(); Text("\(Int(options.padding)) px").foregroundStyle(.secondary).monospacedDigit() }
                Slider(value: $options.padding, in: 4...24, step: 1)
                Text("文字定位框可能不精确。默认整行覆盖并扩边；关闭整行遮挡后，更应放大检查。姓名、地址和头像仍可能漏检，尤其是艺术字体、低清画面或非人脸头像。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("遮挡策略") }
            Section {
                TextEditor(text: $keywords).font(.body).frame(minHeight: 130).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityLabel("自定义敏感关键词，每行一个")
                Text("每行一个，最多 200 条、每条 256 字符。适合姓名、昵称、公司名、订单号或内部项目代号。按字面匹配，不执行正则表达式。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("自己的敏感词") }
            Section("安全导出") {
                Label("墨色、纸白和隐私像素块均为不透明覆盖", systemImage: "rectangle.fill")
                Text("隐私像素块是独立生成的装饰色块，不采样敏感原图。导出的 PNG / JPEG 只含处理后像素，不附带原图、文字识别结果、编辑图层或来源照片的 EXIF / GPS 数据。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("自动识别与复检均不能保证零遗漏。对外分享前，必须人工检查最终预览。")
                    .font(.footnote.weight(.medium)).foregroundStyle(.orange)
            }
            if defaults {
                Section("本机数据") {
                    Text("草稿和临时文件使用 iOS 文件保护，并排除系统备份。关闭或切换应用时，会用隐私遮罩覆盖预览。删除项目只影响本应用内的副本。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("清理导出临时文件", role: .destructive) { clearCache = true }
                    Text("导出缓存保留最长约 24 小时，下次打开应用时清理。已经保存到相册或分享出去的副本不会被清理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("版本", value: "0.1 · Astra")
                    LabeledContent("平台", value: "iOS / iPadOS 17+")
                    Text("原生 SwiftUI、Vision、AVFoundation。没有账号、广告、分析 SDK 或云端识别服务。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("隐私规则").navigationBarTitleDisplayMode(.inline)
        .onAppear { keywords = options.keywords.joined(separator: "\n") }
        .onChange(of: keywords) { _, value in
            options.keywords = Array(value.split(separator: "\n").map { String($0.trimmingCharacters(in: .whitespaces).prefix(256)) }.filter { !$0.isEmpty }.prefix(200))
        }
        .confirmationDialog("清理尚未保存的导出文件？", isPresented: $clearCache, titleVisibility: .visible) {
            Button("清理", role: .destructive) {
                Task {
                    do { try await MediaWorker.shared.cleanExports(all: true); notice = Notice(title: "已清理", message: "导出临时文件已删除。") }
                    catch { notice = Notice(title: "清理失败", message: error.localizedDescription) }
                }
            }
        }.notice($notice)
    }
}
