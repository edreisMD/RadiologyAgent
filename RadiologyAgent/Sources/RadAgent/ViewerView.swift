import SwiftUI
import RadAgentImaging

struct ViewerView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(ViewerTool.allCases) { tool in
                    IconButton(symbol: tool.symbol, help: "\(tool.rawValue) (\(tool.shortcut))", active: model.viewerTool == tool) { model.viewerTool = tool }
                }
                Spacer(minLength: 4)
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Fit image (F)") { model.fitViewer() }
                Menu {
                    Button("Default window") { model.restoreDefaultWindow() }
                    Button(model.inverted ? "Restore grayscale (I)" : "Invert grayscale (I)") { model.inverted.toggle() }
                    Divider()
                    Button("Lung") { model.changeWindow(1500, -600) }
                    Button("Soft tissue") { model.changeWindow(400, 40) }
                    Button("Bone") { model.changeWindow(2000, 300) }
                    Button("Brain") { model.changeWindow(80, 40) }
                } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 13)).foregroundStyle(Theme.muted).frame(width: 29, height: 28) }.menuStyle(.borderlessButton).modifier(ControlHover()).frame(width: 29).help("Window presets")
                if let series = model.currentSeries {
                    Button("Open in Horos") { model.openNativeSeries(series) }.font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.horizontal, 6).frame(height: 28).buttonStyle(HoverButton()).disabled(model.openingSeriesID != nil)
                }
            }.padding(.horizontal, 12).frame(height: 39)
            ZStack {
                DICOMViewport(image: model.evidencePreview?.image ?? model.renderedImage,
                    imageID: model.evidencePreview?.reference.imageID ?? model.currentFrame?.id.uuidString ?? "",
                    seriesID: model.currentSeries?.id ?? model.selectedID,
                    tool: model.viewerTool, zoom: model.zoom, resetID: model.viewerResetID,
                    width: model.windowWidth, center: model.windowCenter, inverted: model.inverted && model.evidencePreview == nil,
                    previewing: model.evidencePreview != nil,
                    onZoom: { model.zoom = $0 }, onWindow: { model.changeWindow($0, $1) },
                    onStep: { model.stepFrame($0) }, onTool: { model.viewerTool = $0 },
                    onReset: { model.fitViewer() }, onInvert: { model.inverted.toggle() },
                    onOpenNative: { if let series = model.currentSeries { model.openNativeSeries(series) } })
                VStack {
                    HStack {
                        if let active = model.activeEvidence {
                            let group = model.activeEvidenceGroup
                            Button("\(model.evidencePreview == nil ? "Key image" : "Preview") \((group.firstIndex(where: { $0.id == active.id }) ?? 0) + 1)/\(group.count)") { model.nextEvidenceImage() }.buttonStyle(HoverButton()).font(.system(size: 11)).padding(6).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5)).help("Next image linked to this phrase")
                        }
                        Spacer()
                        if model.loadingFrame { ProgressView().controlSize(.mini).padding(8).background(.black.opacity(0.6), in: Circle()) }
                    }
                    Spacer()
                    HStack {
                        Text(model.framePositionLabel)
                        Spacer()
                        Text(abs(model.zoom - 1) < 0.01 ? "Fit" : String(format: "%.1f× fit", model.zoom))
                        if model.renderedImage != nil { Text("W \(Int(model.evidencePreview?.reference.windowWidth ?? model.displayedWindowWidth))  L \(Int(model.evidencePreview?.reference.windowCenter ?? model.displayedWindowCenter))") }
                    }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.7)).padding(6).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4)).allowsHitTesting(false)
                }.padding(10)
                if model.frames.isEmpty && !model.loadingFrame { Button("Open study") { model.showLibrary = true }.buttonStyle(FlatButton()) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            if model.currentSeriesIndices.count > 1 {
                HStack(spacing: 8) {
                    IconButton(symbol: "chevron.left", help: "Previous image") { model.stepFrame(-1) }.disabled(model.seriesFramePosition == 0)
                    Slider(value: Binding(get: { Double(model.seriesFramePosition) }, set: { value in
                        let indices = model.currentSeriesIndices
                        if indices.indices.contains(Int(value)) { model.selectFrame(indices[Int(value)], preservePresentation: true) }
                    }), in: 0...Double(max(1, model.currentSeriesIndices.count - 1)), step: 1).tint(Theme.accent).controlSize(.mini)
                    IconButton(symbol: "chevron.right", help: "Next image") { model.stepFrame(1) }.disabled(model.seriesFramePosition >= model.currentSeriesIndices.count - 1)
                }.padding(.horizontal, 12).frame(height: 32)
            }
            if !model.series.isEmpty { SeriesStripView() }
        }
    }
}

struct SeriesStripView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(model.series.enumerated()), id: \.element.id) { index, series in
                    let active = series.frames.contains { $0.id == model.currentFrame?.backend?.id }
                    let name = series.name.isEmpty || series.name == "unnamed" ? "Series \(index + 1)" : series.name
                    Button { model.selectSeries(series) } label: {
                        HStack(spacing: 9) {
                            ZStack {
                                Color.black
                                if let image = model.thumbnails[series.id] { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                                if model.openingSeriesID == series.id { ProgressView().controlSize(.mini) }
                            }.frame(width: 43, height: 43).clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 4) { Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1); Text("\(series.frames.count) image\(series.frames.count == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                            Spacer(minLength: 0)
                            Image(systemName: active ? "checkmark" : "square").font(.system(size: 9)).foregroundStyle(Theme.muted)
                        }.padding(6).frame(width: 146).background(active ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(HoverButton()).disabled(model.openingSeriesID != nil)
                        .accessibilityLabel("View \(name)").help("View \(name) here")
                        .contextMenu { Button("View here") { model.selectSeries(series) }; Button("Open in Horos") { model.selectSeries(series, openNative: true) } }
                        .task(id: series.id) { await model.loadThumbnail(series) }
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }.scrollIndicators(.hidden).frame(height: 71)
    }
}
