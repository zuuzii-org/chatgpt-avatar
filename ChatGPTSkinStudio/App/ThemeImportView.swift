import AppKit
import SwiftUI

struct ThemeImportView: View {
    private enum FocusedField: Hashable {
        case name
    }

    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: FocusedField?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StudioVisualTokens.line)
            content
            Divider().overlay(StudioVisualTokens.line)
            footer
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 620, idealHeight: 680)
        .background(StudioVisualTokens.canvas)
        .foregroundStyle(StudioVisualTokens.text)
        .interactiveDismissDisabled(model.themeImportPhase.isBusy)
        .onChange(of: model.themeImportPhase) { _, phase in
            if phase == .editing {
                focusedField = .name
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: model.themeImportPhase
        )
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(StudioVisualTokens.cyan.opacity(0.14))
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(StudioVisualTokens.cyan)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text("导入图片主题")
                    .font(.title3.weight(.semibold))
                Text("图片会在本机重新编码并移除元数据；预览和保存不会重启 ChatGPT。")
                    .font(.caption)
                    .foregroundStyle(StudioVisualTokens.muted)
            }
            Spacer()
            Button {
                model.dismissThemeImport()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioVisualTokens.muted)
            .disabled(model.themeImportPhase == .committing)
            .accessibilityLabel("关闭导入")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var content: some View {
        switch model.themeImportPhase {
        case .idle:
            emptyState
        case .preparing(let fileName):
            preparingState(fileName: fileName)
        case .editing:
            editor(errorMessage: nil)
        case .committing:
            editor(errorMessage: nil)
                .overlay {
                    busyOverlay(title: "正在安全保存主题…")
                }
        case .succeeded:
            successState
        case .failed(let message):
            if model.themeImportDraft != nil {
                editor(errorMessage: message)
            } else {
                failureState(message: message)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "选择一张图片开始",
            systemImage: "photo.on.rectangle.angled",
            description: Text("支持静态 PNG、JPEG、WebP、HEIC 与 HEIF。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func preparingState(fileName: String) -> some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StudioVisualTokens.elevated)
                .frame(width: 420, height: 260)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(StudioVisualTokens.muted.opacity(0.55))
                }
                .accessibilityHidden(true)
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 5) {
                Text("正在验证并规格化图片")
                    .font(.headline)
                Text(fileName)
                    .font(.caption.monospaced())
                    .foregroundStyle(StudioVisualTokens.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在验证并规格化图片 \(fileName)")
    }

    private func editor(errorMessage: String?) -> some View {
        ScrollView {
            Group {
                if let draft = model.themeImportDraft,
                   let image = NSImage(data: draft.imageData)
                {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("设置视觉焦点")
                                .font(.headline)
                            Text("拖动十字焦点；原图不会被永久裁切。")
                                .font(.caption)
                                .foregroundStyle(StudioVisualTokens.muted)

                            FocalPointEditor(
                                image: image,
                                pixelWidth: draft.pixelWidth,
                                pixelHeight: draft.pixelHeight,
                                focalX: $model.themeImportFocalX,
                                focalY: $model.themeImportFocalY
                            )
                            .frame(minHeight: 330)
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("主题名称")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(StudioVisualTokens.muted)
                                TextField("例如：山岚夜色", text: $model.themeImportDisplayName)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .name)
                                    .accessibilityLabel("主题名称")
                            }

                            CoverThemePreview(
                                image: image,
                                pixelWidth: draft.pixelWidth,
                                pixelHeight: draft.pixelHeight,
                                focalX: model.themeImportFocalX,
                                focalY: model.themeImportFocalY
                            )
                            .frame(height: 155)

                            focalSlider(
                                title: "水平焦点",
                                value: $model.themeImportFocalX,
                                leadingSymbol: "arrow.left",
                                trailingSymbol: "arrow.right"
                            )
                            focalSlider(
                                title: "垂直焦点",
                                value: $model.themeImportFocalY,
                                leadingSymbol: "arrow.up",
                                trailingSymbol: "arrow.down"
                            )

                            HStack(spacing: 10) {
                                metadataPill("\(draft.pixelWidth) × \(draft.pixelHeight)")
                                metadataPill(draft.format.rawValue.uppercased())
                            }

                            ForEach(Array(draft.warnings.enumerated()), id: \.offset) { _, warning in
                                warningRow(warning)
                            }

                            if let errorMessage {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(StudioVisualTokens.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(StudioVisualTokens.red.opacity(0.1))
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                    .accessibilityLabel("保存失败：\(errorMessage)")
                            }
                        }
                        .frame(width: 290)
                    }
                    .padding(24)
                } else {
                    failureState(message: "规格化图片无法创建本地预览。")
                }
            }
        }
    }

    private func focalSlider(
        title: String,
        value: Binding<Double>,
        leadingSymbol: String,
        trailingSymbol: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(StudioVisualTokens.muted)
            }
            HStack(spacing: 8) {
                Image(systemName: leadingSymbol)
                    .accessibilityHidden(true)
                Slider(value: value, in: 0...1)
                    .accessibilityLabel(title)
                    .accessibilityValue(
                        "\(Int((value.wrappedValue * 100).rounded()))%"
                    )
                Image(systemName: trailingSymbol)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(StudioVisualTokens.muted)
        }
        .accessibilityElement(children: .contain)
    }

    private func metadataPill(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(StudioVisualTokens.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(StudioVisualTokens.elevated)
            .clipShape(Capsule())
    }

    private func warningRow(_ warning: ThemeImportWarning) -> some View {
        Label(warningMessage(warning), systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(StudioVisualTokens.amber)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warningMessage(_ warning: ThemeImportWarning) -> String {
        switch warning {
        case let .downsampled(originalWidth, originalHeight, outputWidth, outputHeight):
            "已从 \(originalWidth)×\(originalHeight) 优化为 \(outputWidth)×\(outputHeight)。"
        case let .lowResolution(width, height):
            "图片仅 \(width)×\(height)，在大窗口中可能不够清晰。"
        }
    }

    private func failureState(message: String) -> some View {
        ContentUnavailableView {
            Label("无法导入这张图片", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
        } actions: {
            Button("选择其他图片…") {
                model.chooseAnotherThemeImage()
            }
            .buttonStyle(.borderedProminent)
            .tint(StudioVisualTokens.cyan)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var successState: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(StudioVisualTokens.green)
            VStack(spacing: 6) {
                Text("主题已准备好")
                    .font(.title2.weight(.semibold))
                Text("新主题已加入主题库并被选中。应用时才会连接 ChatGPT。")
                    .foregroundStyle(StudioVisualTokens.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func busyOverlay(title: String) -> some View {
        ZStack {
            StudioVisualTokens.canvas.opacity(0.8)
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(title)
                    .font(.headline)
            }
            .padding(28)
            .background(StudioVisualTokens.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if canChooseAnotherImage {
                Button("选择其他图片…") {
                    model.chooseAnotherThemeImage()
                }
                .disabled(model.themeImportPhase.isBusy)
            }

            Spacer()

            switch model.themeImportPhase {
            case .succeeded:
                Button("完成") {
                    model.dismissThemeImport()
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioVisualTokens.cyan)
                .keyboardShortcut(.defaultAction)
            default:
                Button("取消", role: .cancel) {
                    model.dismissThemeImport()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.themeImportPhase == .committing)

                Button(model.themeImportPhase == .committing ? "正在保存…" : "保存到主题库") {
                    Task { await model.commitThemeImport() }
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioVisualTokens.cyan)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCommitThemeImport)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var canChooseAnotherImage: Bool {
        guard model.themeImportDraft != nil else { return false }
        switch model.themeImportPhase {
        case .editing, .failed:
            return true
        default:
            return false
        }
    }
}

private struct FocalPointEditor: View {
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    @Binding var focalX: Double
    @Binding var focalY: Double

    var body: some View {
        GeometryReader { proxy in
            let imageSize = CGSize(width: pixelWidth, height: pixelHeight)
            let imageRect = fittedRect(imageSize: imageSize, in: proxy.size)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(StudioVisualTokens.elevated)

                Image(nsImage: image)
                    .resizable()
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { updateFocalPoint(location: $0.location, imageRect: imageRect) }
                    )

                focalMarker
                    .position(
                        x: imageRect.minX + (imageRect.width * focalX),
                        y: imageRect.minY + (imageRect.height * focalY)
                    )
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(StudioVisualTokens.line, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("图片焦点编辑器")
        .accessibilityValue(
            "水平 \(Int((focalX * 100).rounded()))%，垂直 \(Int((focalY * 100).rounded()))%"
        )
        .accessibilityAction(named: "重置到中心") {
            focalX = 0.5
            focalY = 0.5
        }
    }

    private var focalMarker: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.36))
                .frame(width: 36, height: 36)
            Circle()
                .stroke(.white, lineWidth: 2)
                .frame(width: 28, height: 28)
            Rectangle()
                .fill(.white)
                .frame(width: 12, height: 2)
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: 12)
        }
        .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
    }

    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func updateFocalPoint(location: CGPoint, imageRect: CGRect) {
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        focalX = min(max((location.x - imageRect.minX) / imageRect.width, 0), 1)
        focalY = min(max((location.y - imageRect.minY) / imageRect.height, 0), 1)
    }
}

private struct CoverThemePreview: View {
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    let focalX: Double
    let focalY: Double

    var body: some View {
        FocalCoverImage(
            image: image,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            focalX: focalX,
            focalY: focalY
        )
        .overlay {
            LinearGradient(
                colors: [.clear, StudioVisualTokens.canvas.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text("CHATGPT FULL 预览")
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.55))
                .clipShape(Capsule())
                .padding(9)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(StudioVisualTokens.line, lineWidth: 1)
        }
        .accessibilityLabel("ChatGPT Full 裁切预览")
        .accessibilityElement(children: .ignore)
    }
}

struct FocalCoverImage: View {
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    let focalX: Double
    let focalY: Double

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.size
            let imageSize = CGSize(width: pixelWidth, height: pixelHeight)
            let scale = max(
                container.width / max(imageSize.width, 1),
                container.height / max(imageSize.height, 1)
            )
            let scaledSize = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )

            Image(nsImage: image)
                .resizable()
                .frame(width: scaledSize.width, height: scaledSize.height)
                .offset(
                    x: (container.width - scaledSize.width) * (focalX - 0.5),
                    y: (container.height - scaledSize.height) * (focalY - 0.5)
                )
                .frame(width: container.width, height: container.height)
            }
    }
}
