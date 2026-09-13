import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var settings = false
    @State private var pendingDeletion: Project?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        HStack(spacing: 9) {
                            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.picAccent)
                            Text("PicSig").font(.system(size: 25, weight: .bold, design: .rounded))
                        }
                        Spacer()
                        Button { settings = true } label: { Image(systemName: "slider.horizontal.3").font(.title3).frame(width: 44, height: 44).background(.background, in: Circle()) }
                            .accessibilityLabel("隐私规则与设置")
                    }
                    hero
                    VStack(alignment: .leading, spacing: 13) {
                        Text("从一个片段开始").font(.headline)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 13) {
                            startCard(.scroll, subtitle: "识别重叠 · 接得自然", color: .picAccent)
                            startCard(.video, subtitle: "滚动录屏 · 变成长图", color: .picMint)
                            startCard(.vertical, subtitle: "照片上下排列", color: .orange)
                            startCard(.horizontal, subtitle: "并排展示 · 自由留白", color: .blue)
                        }
                    }
                    HStack(spacing: 13) {
                        Image(systemName: "checkmark.shield.fill").font(.title2).foregroundStyle(Color.picMint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("先拼完整，再放心分享").font(.subheadline.weight(.semibold))
                            Text("本机识别敏感信息，支持逐项复核与同内容批量遮挡。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.cardSurface()
                    projectSection
                    Button { Task { await library.openDemo() } } label: {
                        Label("用示例体验一次", systemImage: "sparkles").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(16)
                    }.background(Color.picAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18)).accessibilityIdentifier("open-demo")
                    Text("ASTRA EDITION · 本机处理 · 无需账号").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.3).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                }.padding(22).frame(maxWidth: 860).frame(maxWidth: .infinity)
            }.background(Color.picCanvas).toolbar(.hidden, for: .navigationBar)
        }
        .fullScreenCover(item: $library.active, onDismiss: { Task { await library.reload() } }) { session in StudioView(session: session) }
        .sheet(isPresented: $settings) {
            NavigationStack {
                PrivacySettingsView(options: $library.defaults, defaults: true)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { Task { await library.saveDefaults(); settings = false } } } }
            }
        }
        .confirmationDialog("删除这个项目？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
            Button("删除项目及其本机素材", role: .destructive) { if let project = pendingDeletion { Task { await library.delete(project) } }; pendingDeletion = nil }
        } message: { Text("不会删除相册中的原始照片，也不会删除已经分享出去的图片。") }
        .notice($library.notice)
    }
    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("把内容连起来。\n把隐私藏起来。").font(.system(size: 34, weight: .bold, design: .rounded)).tracking(-1).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Circle().fill(Color.picMint).frame(width: 6, height: 6)
                Text("长截图 / 自由拼图 / 隐私编辑").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 12)
    }
    private func startCard(_ kind: ProjectKind, subtitle: String, color: Color) -> some View {
        Button { library.create(kind) } label: {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: kind.symbol).font(.system(size: 25, weight: .medium)).foregroundStyle(color)
                        .frame(width: 49, height: 49).background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(kind.title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, minHeight: 120, alignment: .leading).cardSurface()
        }.buttonStyle(.plain).accessibilityIdentifier("create-\(kind.rawValue)")
    }
    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("本机项目").font(.headline); Spacer(); Text("\(library.projects.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if library.unreadableCount > 0 {
                Label("\(library.unreadableCount) 个项目暂时无法读取，原文件已保留。", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if library.projects.isEmpty {
                HStack(spacing: 16) {
                    Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 30)).foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("第一张长图，从这里开始").font(.subheadline.weight(.medium))
                        Text("编辑自动保存，稍后也能继续。项目封面不展示原图，避免隐私外露。").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).cardSurface()
            } else {
                ForEach(library.projects) { project in
                    Button { library.open(project) } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14).fill(Color.picAccent.opacity(0.09)).frame(width: 56, height: 65)
                                Image(systemName: project.kind.symbol).font(.title2).foregroundStyle(Color.picAccent)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(project.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                Text("\(project.images.count) 张素材 · \(project.updatedAt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                                if !project.edit.masks.isEmpty { Label("\(project.edit.masks.filter(\.enabled).count) 处遮挡", systemImage: "shield.lefthalf.filled").font(.caption2).foregroundStyle(Color.picMint) }
                            }
                            Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.cardSurface()
                    }.buttonStyle(.plain).contextMenu { Button("删除项目", systemImage: "trash", role: .destructive) { pendingDeletion = project } }
                }
            }
        }
    }
}
