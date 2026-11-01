import AppKit
import SwiftUI

// The preview is a fixed work area: controls stay visible while the canvas
// receives all remaining height. The host provides the import/settings sidebar.
private enum PreviewStudioColors {
    static let canvas = Color(red: 0.052, green: 0.060, blue: 0.067)
    static let panel = Color(red: 0.103, green: 0.115, blue: 0.126)
    static let raised = Color(red: 0.137, green: 0.152, blue: 0.167)
    static let line = Color.white.opacity(0.085)
    static let muted = Color.white.opacity(0.50)
}

private final class PreviewCanvasPresentation: ObservableObject {
    @Published var fillsPanels = false
    @Published var showsDetails = false
}

struct PhotoPreviewPanel: View {
    @ObservedObject var model: PhotoPreviewModel
    // Retained for compatibility with earlier hosts. The studio canvas expands
    // with its parent rather than assigning a fixed image height.
    var imageHeight: CGFloat = 300
    @StateObject private var presentation = PreviewCanvasPresentation()

    var body: some View {
        VStack(spacing: 0) {
            workspaceToolbar
            rule
            comparisonCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.comparisonMode == "split", model.after != nil {
                splitControl
                rule
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(Color(red: 1, green: 0.56, blue: 0.52))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.red.opacity(0.08))
                rule
            }
            if model.comparisonMode == "split" {
                filmstrip
                rule
            }
            statusBar
        }
        .background(PreviewStudioColors.panel)
        .foregroundStyle(.white.opacity(0.88))
        .preferredColorScheme(.dark)
        .onReceive(model.$photoURL) { _ in presentation.fillsPanels = false }
    }

    private var rule: some View {
        Rectangle().fill(PreviewStudioColors.line).frame(height: 1)
    }

    private var workspaceToolbar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Picker("对比方式", selection: $model.comparisonMode) {
                    Text("多图对比").tag("compare")
                    Text("滑动对比").tag("split")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                Text("原图 + \(model.selectedLookURLs.count) \(model.lookURL == nil ? "" : model.lookKind)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PreviewStudioColors.muted).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
                if model.isRendering {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Button("取消", action: model.cancel)
                        .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button(action: model.render) { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("重新预览").help("重新生成照片预览")
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(model.photoURL == nil)
                }
                Button(action: model.exportPreview) {
                    Label(model.comparisonMode == "compare" ? "导出选中项" : "导出 PNG", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(model.after == nil || model.isRendering)
                .help("导出选中项的完整预览；缩放、定位和填充裁切不会写入 PNG。")
            }
            HStack(spacing: 9) {
                if model.comparisonMode == "compare" {
                    HStack(spacing: 0) {
                        displayModeButton("完整显示", fills: false)
                        displayModeButton("填充显示", fills: true)
                    }
                    .background(PreviewStudioColors.raised, in: RoundedRectangle(cornerRadius: 5))
                    .frame(width: 170)
                }
                Text("缩放").font(.system(size: 10)).foregroundStyle(PreviewStudioColors.muted)
                Menu {
                    Button("适合窗口") { setZoom(0) }
                    Divider()
                    ForEach([100, 150, 200], id: \.self) { percent in
                        Button("\(percent)%") { setZoom(percent) }
                    }
                } label: {
                    Text(zoomDisplayText).font(.system(size: 11)).monospacedDigit()
                        .frame(width: 88, alignment: .leading)
                }
                .menuStyle(.borderlessButton).frame(width: 116)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(PreviewStudioColors.raised, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel("联动缩放倍率")
                .accessibilityValue(zoomDisplayText)
                .help("100% 为一个预览图像素对应一个屏幕像素；所有照片保持相同倍率和位置。适合窗口显示完整画面。")
                Button {
                    presentation.fillsPanels = false
                    model.resetPreviewZoom()
                } label: { Label("重置视图", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("恢复完整画面，并将定位点居中。")
                Spacer(minLength: 0)
                Text("单击照片 · 联动放大 / 缩回")
                    .font(.system(size: 10)).foregroundStyle(PreviewStudioColors.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(PreviewStudioColors.panel)
    }

    private var zoomDisplayText: String {
        model.previewZoomPercent > 0 ? "\(model.previewZoomPercent)%" : presentation.fillsPanels && model.comparisonMode == "compare" ? "填充窗口" : "适合窗口"
    }

    private var zoomFactor: CGFloat? {
        model.previewZoomPercent == 0 ? nil : CGFloat(model.previewZoomPercent) / 100
    }

    private func setZoom(_ percent: Int) {
        presentation.fillsPanels = false
        model.setPreviewZoomPercent(percent)
    }

    private func clickedPhoto(at point: CGPoint) {
        presentation.fillsPanels = false
        model.togglePreviewZoom(at: point)
    }

    private func displayModeButton(_ title: String, fills: Bool) -> some View {
        Button {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.setPreviewZoomPercent(0)
                presentation.fillsPanels = fills
            }
        } label: {
            Text(title).font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(model.previewZoomPercent == 0 && presentation.fillsPanels == fills ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(model.previewZoomPercent == 0 && presentation.fillsPanels == fills ? "已选中" : "未选中")
    }

    @ViewBuilder private var comparisonCanvas: some View {
        if model.comparisonMode == "compare" {
            adaptiveComparison
        } else {
            VStack(spacing: 0) {
                HStack {
                    canvasLabel("套用前", subtitle: model.previewMethod == "native" ? "CANON NEUTRAL" : "ORIGINAL")
                    Spacer()
                    canvasLabel("套用后", subtitle: model.isPF3Preview ? "PF3 PREVIEW" : "LUT PREVIEW")
                }.padding(.horizontal, 16).frame(height: 37)
                GeometryReader { geometry in
                    ZStack {
                        PreviewStudioColors.canvas
                        if let before = model.before {
                            splitImage(before: before, available: geometry.size)
                        } else {
                            canvasPlaceholder(isResult: false)
                        }
                    }
                }
                if model.after == nil, model.before != nil {
                    HStack(spacing: 6) {
                        if model.isRendering { ProgressView().controlSize(.mini) }
                        Text(pendingResultText).font(.caption)
                    }
                    .foregroundStyle(PreviewStudioColors.muted)
                    .padding(.bottom, 10)
                }
            }.background(PreviewStudioColors.canvas)
        }
    }

    private var adaptiveComparison: some View {
        GeometryReader { geometry in
            let count = model.comparisonItems.count + 1
            let ratio = model.before.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1.5
            let frames = ComparisonLayout.frames(count: count, in: geometry.size)
            let fittedSize = ComparisonLayout.commonImageSize(in: frames, imageAspectRatio: ratio)
            ZStack(alignment: .topLeading) {
                ForEach(0..<frames.count, id: \.self) { index in
                    adaptiveTile(at: index, panelSize: frames[index].size, fittedSize: fittedSize)
                        .frame(width: frames[index].width, height: frames[index].height)
                        .clipped()
                        .position(x: frames[index].midX, y: frames[index].midY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(PreviewStudioColors.line)
    }

    @ViewBuilder private func adaptiveTile(at index: Int, panelSize: CGSize, fittedSize: CGSize) -> some View {
        if index == 0 {
            imagePane(image: model.before, title: "原图", subtitle: model.previewMethod == "native" ? "CANON NEUTRAL" : "ORIGINAL", isResult: false, panelSize: panelSize, fittedSize: fittedSize)
        } else {
            comparisonTile(at: index - 1, panelSize: panelSize, fittedSize: fittedSize)
        }
    }

    @ViewBuilder private func comparisonTile(at index: Int, panelSize: CGSize, fittedSize: CGSize) -> some View {
        if index < model.comparisonItems.count {
            let item = model.comparisonItems[index]
            let active = model.lookURL == item.url
            let isPF3 = item.url.pathExtension.lowercased() == "pf3"
            ZStack(alignment: .topLeading) {
                PreviewStudioColors.canvas
                if let image = item.image {
                    photoImage(image, in: panelSize, fittedSize: fittedSize) { point in
                        model.focusComparisonLook(item.url)
                        clickedPhoto(at: point)
                    }
                    .accessibilityLabel("\(item.name)，单击照片联动放大或缩回")
                } else {
                    Button { model.focusComparisonLook(item.url) } label: {
                        ZStack {
                            PreviewStudioColors.canvas
                            if let error = item.error {
                                VStack(spacing: 5) {
                                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                    Text(error).font(.system(size: 10)).lineLimit(isPF3 ? 3 : 4)
                                        .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.55))
                                }.padding(16).padding(.bottom, isPF3 ? 24 : 0)
                            } else {
                                VStack(spacing: 7) {
                                    if item.isRendering { ProgressView().controlSize(.small) }
                                    else { Image(systemName: isPF3 ? "doc.badge.gearshape" : "cube.transparent").foregroundStyle(.white.opacity(0.25)) }
                                    Text(model.photoURL == nil ? "导入照片后预览" : item.isRendering ? "正在生成…" : "等待预览")
                                        .font(.system(size: 10)).foregroundStyle(PreviewStudioColors.muted)
                                }
                            }
                        }.frame(width: panelSize.width, height: panelSize.height).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("选中 \(item.name) 预览以导出")
                }
                HStack(spacing: 5) {
                    Button { model.focusComparisonLook(item.url) } label: {
                        HStack(spacing: 5) {
                            Text(String(format: "%02d", index + 1))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(active ? Color.accentColor : PreviewStudioColors.muted)
                            Text(item.name).font(.system(size: 10, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.url.pathExtension.uppercased())
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(PreviewStudioColors.muted)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("选中 \(item.name) 预览以导出")
                    .help("选择导出项，保持当前缩放位置。")
                    Button { model.toggleComparisonLook(item.url) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("从对比中移除 \(item.name)")
                    .help("从对比中移除")
                }
                .padding(.leading, 7).padding(.trailing, 2).padding(.vertical, 2)
                .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 4))
                .padding(6)
            }
            .frame(width: panelSize.width, height: panelSize.height)
            .contentShape(Rectangle()).clipped()
            .overlay(Rectangle().strokeBorder(active ? Color.accentColor.opacity(0.85) : .clear, lineWidth: 1.5))
            .overlay(alignment: .bottom) {
                if isPF3, item.error != nil {
                    Button("单独查看") { model.configurePF3(url: item.url) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("单独查看 \(item.name)")
                        .help("只保留这个 PF3，并按它的显影基准生成预览。")
                        .padding(10)
                }
            }
            .help(item.error.map { $0 + "\n" + item.url.path } ?? "单击照片联动缩放；点击标题选择导出项。\n" + item.url.path)
        }
    }

    private func canvasLabel(_ title: String, subtitle: String) -> some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 10, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
            Text(subtitle).font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    private func imagePane(image: CGImage?, title: String, subtitle: String, isResult: Bool,
                           panelSize: CGSize, fittedSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            PreviewStudioColors.canvas
            if let image = image {
                photoImage(image, in: panelSize, fittedSize: fittedSize, onImageClick: clickedPhoto)
                    .accessibilityLabel(isResult ? "套用预设后的照片预览" : "套用预设前的照片预览")
            } else {
                canvasPlaceholder(isResult: isResult)
            }
            canvasLabel(title, subtitle: subtitle)
                .padding(.horizontal, 7).padding(.vertical, 6)
                .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 4))
                .padding(6)
                .allowsHitTesting(false)
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .clipped()
        .contentShape(Rectangle())
    }

    private func photoImage(_ image: CGImage, in panel: CGSize, fittedSize: CGSize,
                            onImageClick: ((CGPoint) -> Void)? = nil) -> some View {
        PreviewPhotoView(image: image, fillsPanels: presentation.fillsPanels, commonFitSize: fittedSize,
                         zoomFactor: zoomFactor, normalizedCenter: model.previewZoomCenter,
                         onImageClick: onImageClick, excludedTopHeight: 36)
            .frame(width: panel.width, height: panel.height)
    }

    private var pendingResultText: String {
        if model.isRendering { return "正在生成套用后预览…" }
        if model.error != nil { return "预览未完成，请查看下方提示" }
        if model.photoURL == nil { return "导入照片后在这里查看效果" }
        if model.lookURL == nil { return "选择 CUBE 或 PF3 后生成预览" }
        return "点击“重新预览”生成效果"
    }

    private func canvasPlaceholder(isResult: Bool) -> some View {
        VStack(spacing: 12) {
            if model.isRendering {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: isResult ? "slider.horizontal.3" : "photo.on.rectangle.angled")
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(.white.opacity(0.25))
            }
            Text(isResult ? pendingResultText : model.isRendering ? "正在读取照片…" : "导入一张照片")
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.60))
            if !isResult, model.photoURL == nil {
                Text("JPEG · PNG · HEIC · TIFF · RAW / CR3")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.30))
                Button("导入照片…", action: model.choosePhoto)
                    .buttonStyle(.bordered).controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func splitImage(before: CGImage, available: CGSize) -> some View {
        let width = max(1, available.width - 24), height = max(1, available.height - 20)
        let viewport = CGSize(width: width, height: height)
        let position = CGFloat(model.splitPosition)
        return ZStack(alignment: .leading) {
            PreviewPhotoView(image: before, commonFitSize: viewport,
                             zoomFactor: zoomFactor, normalizedCenter: model.previewZoomCenter,
                             onImageClick: clickedPhoto,
                             excludedHitRects: model.after == nil ? [] : [CGRect(x: width * position - 15, y: 0, width: 30, height: height)],
                             comparisonImage: model.after, splitPosition: position)
                .frame(width: width, height: height)
            if model.after != nil {
                Rectangle().fill(Color.white.opacity(0.95)).frame(width: 1.5, height: height)
                    .offset(x: width * position - 0.75).allowsHitTesting(false)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(.black.opacity(0.80), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.70), lineWidth: 1))
                    .offset(x: width * position - 14.5).allowsHitTesting(false)
                Rectangle().fill(Color.clear).frame(width: 30, height: height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("linkedSplitViewport")).onChanged { value in
                        model.splitPosition = min(1, max(0, value.location.x / width))
                    })
                    .offset(x: width * position - 15)
                    .accessibilityLabel("拖动照片对比分割线")
            }
        }
        .frame(width: width, height: height)
        .coordinateSpace(name: "linkedSplitViewport")
        .clipped().contentShape(Rectangle())
    }

    private var splitControl: some View {
        HStack(spacing: 12) {
            Text("套用前")
            Slider(value: $model.splitPosition, in: 0...1)
                .accessibilityLabel("照片对比分割位置")
                .accessibilityValue("套用前占 \(Int(model.splitPosition * 100))%")
                .help("拖动画面分割线，或用此滑块调整对比位置。")
            Text("套用后")
        }
        .font(.system(size: 10)).foregroundStyle(PreviewStudioColors.muted)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(PreviewStudioColors.panel)
    }

    private var filmstrip: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(PreviewStudioColors.canvas)
                if let before = model.before {
                    Image(decorative: before, scale: 1).resizable().scaledToFit().padding(4)
                } else {
                    Image(systemName: "photo").foregroundStyle(.white.opacity(0.2))
                }
            }
            .frame(width: 78, height: 57)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(model.before == nil ? PreviewStudioColors.line : Color.accentColor.opacity(0.7), lineWidth: 1))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.photoURL?.lastPathComponent ?? "尚未导入照片")
                    .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .help(model.photoURL?.path ?? "")
                HStack(spacing: 5) {
                    Image(systemName: model.isPF3Preview ? "slider.horizontal.3" : "cube.transparent")
                    Text(model.lookURL?.lastPathComponent ?? "尚未选择 CUBE / PF3")
                        .lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 10)).foregroundStyle(PreviewStudioColors.muted)
                .help(model.lookURL?.path ?? "")
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 5) {
                if let before = model.before {
                    Text("\(before.width) × \(before.height)")
                        .font(.system(size: 10, design: .monospaced))
                }
                Text(model.comparisonMode == "compare" ? "统一缩放 · 点击效果导出" : "sRGB 预览")
                    .font(.system(size: 10)).foregroundStyle(PreviewStudioColors.muted)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(PreviewStudioColors.panel)
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle().fill(model.error != nil ? Color.red : model.after != nil ? Color.green : Color.white.opacity(0.30))
                .frame(width: 5, height: 5)
            Text(model.status).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                .help(model.status)
            Spacer(minLength: 4)
            if model.before != nil {
                Text(model.previewZoomPercent > 0 ? "\(model.previewZoomPercent)% · 联动" : presentation.fillsPanels && model.comparisonMode == "compare" ? "填充 · 边缘裁切" : "完整 · 统一缩放")
                    .font(.system(size: 9)).foregroundStyle(presentation.fillsPanels ? Color.orange.opacity(0.8) : PreviewStudioColors.muted)
                    .fixedSize()
            }
            Button { presentation.showsDetails.toggle() } label: {
                Image(systemName: "info.circle").font(.system(size: 12))
            }
            .buttonStyle(.plain).help("照片和预览说明")
            .accessibilityLabel("查看照片和预览说明")
            .popover(isPresented: $presentation.showsDetails, arrowEdge: .bottom) {
                previewDetails
            }
        }
        .foregroundStyle(PreviewStudioColors.muted)
        .padding(.horizontal, 12).frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PreviewStudioColors.panel)
    }

    private var previewDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("预览详情").font(.headline)
            if let photo = model.photoURL {
                Label(photo.lastPathComponent, systemImage: "photo")
                    .font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                if let before = model.before {
                    Text("预览尺寸 \(before.width) × \(before.height)")
                        .font(.system(size: 10, design: .monospaced))
                }
            }
            if let look = model.lookURL {
                Label(look.lastPathComponent, systemImage: model.isPF3Preview ? "slider.horizontal.3" : "cube.transparent")
                    .font(.system(size: 11)).textSelection(.enabled)
            }
            Text(model.status).font(.system(size: 11)).textSelection(.enabled)
            Divider()
            Text(model.previewExplanation).font(.system(size: 11))
            Text("单击照片上的位置联动放大，再次单击缩回。100% 为一个预览图像素对应一个屏幕像素；切换 PF3 保留倍率和定位点。缩放和填充仅影响查看，PNG 导出保留完整预览。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(18).frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
    }
}
