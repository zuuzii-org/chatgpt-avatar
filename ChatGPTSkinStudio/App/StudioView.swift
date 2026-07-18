import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StudioView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack {
                StudioVisualTokens.canvas.ignoresSafeArea()
                detail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(StudioVisualTokens.canvas)
        .alert("无法完成操作", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
        .disabled(model.isShowingRestartConsent)
        .accessibilityHidden(model.isShowingRestartConsent)
        .overlay {
            if model.isShowingRestartConsent {
                ZStack {
                    StudioVisualTokens.canvas
                        .opacity(0.82)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)

                    RestartConsentView(model: model)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.97).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                }
                .zIndex(10)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: model.isShowingRestartConsent
        )
        .fileImporter(
            isPresented: $model.isShowingThemeImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let sourceURL = urls.first else { return }
                model.prepareThemeImport(from: sourceURL)
            case .failure(let error):
                model.reportThemeImagePickerFailure(error)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.isShowingThemeImport },
                set: { if !$0 { model.dismissThemeImport() } }
            )
        ) {
            ThemeImportView(model: model)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SKIN STUDIO")
                    .font(.caption2.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(StudioVisualTokens.cyan)
                Text("ChatGPT 完整皮肤")
                    .font(.title3.weight(.semibold))
            }
            .padding(.horizontal, 4)

            Spacer()

            statusCard
        }
        .padding(18)
        .frame(minWidth: 238)
        .background(StudioVisualTokens.panel)
    }

    private var statusCard: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(model.state.title)
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioCard()
    }

    private var statusColor: Color {
        switch model.state {
        case .active: StudioVisualTokens.green
        case .incompatible, .degraded, .recoveryRequired: StudioVisualTokens.red
        case .awaitingRestartConsent: StudioVisualTokens.amber
        default: StudioVisualTokens.cyan
        }
    }

    @ViewBuilder
    private var detail: some View {
        ThemeLibraryView(model: model)
    }
}

private struct ThemeLibraryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("原创主题库")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(StudioVisualTokens.text)
                        Text("主题是纯数据；不读取聊天、终端、仓库或剪贴板。")
                            .foregroundStyle(StudioVisualTokens.muted)
                    }
                    Spacer()
                    Button {
                        model.isShowingThemeImagePicker = true
                    } label: {
                        Label("导入图片主题…", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.themeImportPhase.isBusy)
                    statePill
                }

                if model.themes.isEmpty {
                    ContentUnavailableView(
                        "没有可用主题",
                        systemImage: "paintpalette",
                        description: Text("导入一张本地图片，或检查应用资源与用户主题目录。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .studioCard()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 18)], spacing: 18) {
                        ForEach(model.themes, id: \.manifest.id) { theme in
                            ThemeCard(
                                theme: theme,
                                isSelected: model.selectedThemeID == theme.manifest.id
                            ) {
                                model.selectedThemeID = theme.manifest.id
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        model.requestApply()
                    } label: {
                        Label(
                            model.activeThemeID == nil ? "应用到 ChatGPT…" : "无重启切换主题",
                            systemImage: model.activeThemeID == nil
                                ? "paintbrush.pointed.fill"
                                : "arrow.triangle.2.circlepath"
                        )
                            .frame(minWidth: 150)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioVisualTokens.cyan)
                    .disabled(!model.canApply)

                    if model.isActive {
                        Button("恢复原生界面", role: .destructive) {
                            model.requestRestore()
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("在 Finder 中显示") {
                        model.revealThemeDirectory()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.selectedTheme == nil)
                }
            }
            .padding(34)
        }
    }

    private var statePill: some View {
        Text(model.state.title.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.8)
            .foregroundStyle(StudioVisualTokens.cyan)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(StudioVisualTokens.cyan.opacity(0.12))
            .clipShape(Capsule())
            .overlay { Capsule().stroke(StudioVisualTokens.cyan.opacity(0.45)) }
    }
}

private struct ThemeCard: View {
    let theme: LoadedTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let image = NSImage(contentsOf: theme.heroAsset.fileURL) {
                        FocalCoverImage(
                            image: image,
                            pixelWidth: theme.heroAsset.pixelWidth,
                            pixelHeight: theme.heroAsset.pixelHeight,
                            focalX: theme.manifest.hero.focalPoint.x,
                            focalY: theme.manifest.hero.focalPoint.y
                        )
                    } else {
                        Color.black
                    }
                }
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: [.clear, StudioVisualTokens.canvas.opacity(0.92)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 112)
                }
                .overlay(alignment: .topLeading) {
                    Label("主题预览", systemImage: "photo.on.rectangle.angled")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StudioVisualTokens.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(StudioVisualTokens.canvas.opacity(0.78))
                        .clipShape(Capsule())
                        .overlay {
                            Capsule().stroke(StudioVisualTokens.line, lineWidth: 1)
                        }
                        .padding(14)
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(theme.manifest.name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(StudioVisualTokens.text)
                        Text("Home Full · Thread Core")
                            .font(.caption)
                            .foregroundStyle(StudioVisualTokens.muted)
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? StudioVisualTokens.cyan : StudioVisualTokens.muted)
                }
                .padding(18)
            }
            .background(StudioVisualTokens.panel)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? StudioVisualTokens.cyan : StudioVisualTokens.line, lineWidth: isSelected ? 2 : 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
        }
        .buttonStyle(.plain)
    }
}

private struct RestartConsentView: View {
    private enum FocusedAction: Hashable {
        case cancel
        case confirm
    }

    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedAction: FocusedAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(StudioVisualTokens.amber)
            Text(model.pendingRestartAction == .restore ? "重启并恢复原生界面" : "需要重启 ChatGPT")
                .font(.title2.weight(.bold))
            Text(consentMessage)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("取消", role: .cancel) {
                    model.cancelRestart()
                }
                .keyboardShortcut(.cancelAction)
                .focused($focusedAction, equals: .cancel)
                Spacer()
                Button(model.pendingRestartAction == .restore ? "确认重启并恢复" : "确认重启并应用") {
                    Task { await model.confirmRestart() }
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioVisualTokens.amber)
                .focused($focusedAction, equals: .confirm)
            }
        }
        .padding(28)
        .frame(width: 470)
        .background(StudioVisualTokens.panel)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(StudioVisualTokens.amber.opacity(0.5), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.38), radius: 36, y: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            model.pendingRestartAction == .restore
                ? "重启并恢复原生界面确认"
                : "重启并应用主题确认"
        )
        .onAppear {
            focusedAction = .cancel
        }
        .onExitCommand {
            model.cancelRestart()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focusedAction)
    }

    private var consentMessage: String {
        if model.pendingRestartAction == .restore {
            return "Skin Studio 会先清理全部增强节点与 reload 脚本，再退出受管的 ChatGPT 调试会话，并以正常方式重新打开。当前任务会被中断；真实 profile 不会被删除。"
        }
        return "完整皮肤需要以本机会话调试能力启动 ChatGPT。重启后会先执行结构兼容性探测，只有通过才会注入；不兼容时会清理并以正常模式重新打开。当前任务会被中断；调试 listener 会在 ChatGPT 进程存活期间保持在 127.0.0.1。Skin Studio 不安装 watchdog，也不会在没有明确确认时重启。"
    }
}
