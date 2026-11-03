import DiscImageStudioKit
import SwiftUI

struct DesignView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HSplitView {
            layerPanel
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
            DiscCanvas()
                .frame(minWidth: 360)
            inspector
                .frame(minWidth: 270, idealWidth: 290, maxWidth: 340)
        }
    }

    private var layerPanel: some View {
        VStack(spacing: 0) {
            List(selection: $app.selectedLayerID) {
                ForEach(app.layers) { layer in
                    HStack {
                        Button {
                            app.updateLayer(layer.id) { $0.visible.toggle() }
                        } label: {
                            Image(systemName: layer.visible ? "eye" : "eye.slash")
                        }
                        .buttonStyle(.borderless)
                        .help(layer.visible ? "Hide layer" : "Show layer")
                        Text(layer.name).lineLimit(1).truncationMode(.middle)
                    }
                    .tag(layer.id)
                }
            }
            .overlay {
                if app.layers.isEmpty {
                    ContentUnavailableView("No images yet", systemImage: "photo",
                                           description: Text("Import an image to start the design."))
                }
            }
            Divider()
            HStack {
                Button { app.importImages() } label: { Label("Import", systemImage: "plus") }
                Spacer()
                Button { app.moveSelectedLayer(by: -1) } label: { Image(systemName: "arrow.up") }
                    .help("Move layer up").disabled(!canMove(-1))
                Button { app.moveSelectedLayer(by: 1) } label: { Image(systemName: "arrow.down") }
                    .help("Move layer down").disabled(!canMove(1))
                Button { app.removeSelectedLayer() } label: { Image(systemName: "trash") }
                    .help("Remove layer").disabled(app.selectedLayerID == nil)
            }
            .padding(8)
        }
    }

    private func canMove(_ offset: Int) -> Bool {
        guard let index = app.layers.firstIndex(where: { $0.id == app.selectedLayerID }) else { return false }
        return app.layers.indices.contains(index + offset)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Layer") { layerProperties.padding(4) }
                GroupBox("Tone") { TonePanel().padding(4) }
            }
            .padding(10)
        }
    }

    @ViewBuilder private var layerProperties: some View {
        if let id = app.selectedLayerID, let layer = app.layers.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 8) {
                NumberField(title: "X", value: binding(id, \.translateXMm, layer.translateXMm), unit: "mm", decimals: 2)
                NumberField(title: "Y", value: binding(id, \.translateYMm, layer.translateYMm), unit: "mm", decimals: 2)
                NumberField(title: "Rotation", value: binding(id, \.rotationDeg, layer.rotationDeg), unit: "°", decimals: 1)
                NumberField(title: "Scale", value: Binding(
                    get: { layer.scale * 100 },
                    set: { value in
                        guard value > 0 else { return }
                        app.updateLayer(id) { $0.scale = value / 100 }
                    }
                ), unit: "%", decimals: 1)
                Button("Reset Placement") {
                    app.updateLayer(id) {
                        $0.translateXMm = 0
                        $0.translateYMm = 0
                        $0.rotationDeg = 0
                        $0.scale = 1
                    }
                }
            }
        } else {
            Text("Select a layer to edit it.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func binding(_ id: String, _ key: WritableKeyPath<DesignLayer, Double>, _ current: Double) -> Binding<Double> {
        Binding(get: { current }, set: { value in app.updateLayer(id) { $0[keyPath: key] = value } })
    }
}

/// Tone is a generation setting, so it lives here and is saved with the project.
struct TonePanel: View {
    @EnvironmentObject private var app: AppModel

    private var tone: ToneProfile { app.project?.tone ?? ToneProfile(ditherStrength: 0, levels: 2, brightness: 0) }
    private var family: DiscFamily { app.project?.discFamily ?? .cd }

    private func set(_ change: @escaping (inout ToneProfile) -> Void) {
        app.updateProject { document in
            var value = document.tone ?? ToneProfile(ditherStrength: 0, levels: 2, brightness: 0)
            change(&value)
            document.tone = value
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Circle().fill(.quaternary)
                if let image = app.tonePreview {
                    Image(nsImage: image).resizable().scaledToFit()
                }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(app.tonePreviewStatus).font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Dither: \(Int((tone.ditherStrength * 100).rounded()))%").font(.callout)
                Slider(value: Binding(get: { tone.ditherStrength }, set: { value in set { $0.ditherStrength = value } }), in: 0...1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Brightness: \(Int(tone.brightness.rounded()))").font(.callout)
                Slider(value: Binding(get: { tone.brightness }, set: { value in set { $0.brightness = value } }), in: -64...64)
            }
            Toggle("sRGB linearization (gamma)", isOn: Binding(get: { tone.srgbLinearization }, set: { value in set { $0.srgbLinearization = value } }))
            if family == .cd {
                Picker("Gray levels", selection: Binding(get: { tone.levels }, set: { value in set { $0.levels = value } })) {
                    Text("2").tag(2)
                    Text("4").tag(4)
                }
                .pickerStyle(.segmented)
            }
            if family == .bd {
                Toggle("Swap 3T/6T assignment", isOn: Binding(
                    get: { app.project?.bluRay?.invertMapping ?? false },
                    set: { value in app.updateProject { $0.bluRay = ProjectBluRaySettings(invertMapping: value) } }
                ))
            }
        }
    }
}

/// The design surface: millimetre coordinates centred on the disc, y down, matching project
/// files. Layers can be dragged, scaled by a corner, and rotated by the top handle.
struct DiscCanvas: View {
    @EnvironmentObject private var app: AppModel
    @State private var drag: DragKind?

    private enum DragKind {
        case move(id: String, startX: Double, startY: Double)
        case scale(id: String, start: Double, startDistance: Double)
        case rotate(id: String, start: Double, startAngle: Double)
    }

    private let handleHitRadius: CGFloat = 12
    private let rotateHandleOffset: CGFloat = 26

    var body: some View {
        GeometryReader { proxy in
            let mapping = Mapping(size: proxy.size, radius: viewRadius)
            Canvas { context, _ in draw(&context, mapping) }
                .contentShape(Rectangle())
                .gesture(dragGesture(mapping))
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    /// The view shows the physical disc, or the canvas if that's larger.
    private var viewRadius: Double { max(app.canvasOuterRadiusMm, 60) + 2 }

    private struct Mapping {
        var size: CGSize
        var radius: Double

        var scale: Double { min(size.width, size.height) / (2 * radius) }
        var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
        func point(_ xMm: Double, _ yMm: Double) -> CGPoint {
            CGPoint(x: center.x + xMm * scale, y: center.y + yMm * scale)
        }
        func mm(_ point: CGPoint) -> (x: Double, y: Double) {
            ((point.x - center.x) / scale, (point.y - center.y) / scale)
        }
    }

    // MARK: Drawing

    private func circle(_ m: Mapping, _ radiusMm: Double) -> Path {
        let r = radiusMm * m.scale
        return Path(ellipseIn: CGRect(x: m.center.x - r, y: m.center.y - r, width: 2 * r, height: 2 * r))
    }

    private func draw(_ context: inout GraphicsContext, _ m: Mapping) {
        guard let geometry = app.project?.geometry else { return }
        context.fill(circle(m, 60), with: .color(Color(nsColor: .controlBackgroundColor)))

        for layer in app.layers.reversed() where layer.visible {
            guard let image = layer.image else { continue }
            var layerContext = context
            layerContext.clip(to: circle(m, 60))
            let center = m.point(layer.translateXMm, layer.translateYMm)
            layerContext.translateBy(x: center.x, y: center.y)
            layerContext.rotate(by: .degrees(layer.rotationDeg))
            let w = layer.baseWidthMm * layer.scale * m.scale
            let h = layer.baseHeightMm * layer.scale * m.scale
            layerContext.draw(Image(decorative: image, scale: 1), in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        }

        // Only the drawable ring reaches the disc: everything outside it is dimmed.
        var dim = Path()
        dim.addEllipse(in: circle(m, 60).boundingRect)
        dim.addEllipse(in: circle(m, geometry.outerRadiusMm).boundingRect)
        context.fill(dim, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
        context.fill(circle(m, geometry.innerRadiusMm), with: .color(.black.opacity(0.35)))
        context.fill(circle(m, 7.5), with: .color(Color(nsColor: .underPageBackgroundColor)))

        context.stroke(circle(m, 60), with: .color(.secondary), lineWidth: 1)
        context.stroke(circle(m, geometry.outerRadiusMm), with: .color(.accentColor.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        context.stroke(circle(m, geometry.innerRadiusMm), with: .color(.accentColor.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

        if let layer = selectedLayer { drawSelection(&context, layer, m) }
    }

    private func drawSelection(_ context: inout GraphicsContext, _ layer: DesignLayer, _ m: Mapping) {
        let corners = corners(of: layer, m)
        var outline = Path()
        outline.addLines(corners + [corners[0]])
        context.stroke(outline, with: .color(.accentColor), lineWidth: 1.5)
        for corner in corners {
            let box = CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8)
            context.fill(Path(box), with: .color(.white))
            context.stroke(Path(box), with: .color(.accentColor), lineWidth: 1.5)
        }
        let top = midpoint(corners[0], corners[1])
        let handle = rotateHandle(of: layer, m)
        var stem = Path()
        stem.move(to: top)
        stem.addLine(to: handle)
        context.stroke(stem, with: .color(.accentColor), lineWidth: 1.5)
        let knob = CGRect(x: handle.x - 5, y: handle.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: knob), with: .color(.white))
        context.stroke(Path(ellipseIn: knob), with: .color(.accentColor), lineWidth: 1.5)
    }

    // MARK: Layer geometry

    private var selectedLayer: DesignLayer? {
        app.layers.first { $0.id == app.selectedLayerID && $0.visible && $0.image != nil }
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Screen positions of the corners, clockwise from top-left.
    private func corners(of layer: DesignLayer, _ m: Mapping) -> [CGPoint] {
        let center = m.point(layer.translateXMm, layer.translateYMm)
        let w = layer.baseWidthMm * layer.scale * m.scale / 2
        let h = layer.baseHeightMm * layer.scale * m.scale / 2
        let angle = layer.rotationDeg * .pi / 180
        return [(-w, -h), (w, -h), (w, h), (-w, h)].map { x, y in
            CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
        }
    }

    private func rotateHandle(of layer: DesignLayer, _ m: Mapping) -> CGPoint {
        let c = corners(of: layer, m)
        let top = midpoint(c[0], c[1])
        let angle = layer.rotationDeg * .pi / 180
        return CGPoint(x: top.x + rotateHandleOffset * sin(angle), y: top.y - rotateHandleOffset * cos(angle))
    }

    private func contains(_ layer: DesignLayer, _ point: CGPoint, _ m: Mapping) -> Bool {
        let mm = m.mm(point)
        let dx = mm.x - layer.translateXMm, dy = mm.y - layer.translateYMm
        let angle = -layer.rotationDeg * .pi / 180
        let x = dx * cos(angle) - dy * sin(angle)
        let y = dx * sin(angle) + dy * cos(angle)
        return abs(x) <= layer.baseWidthMm * layer.scale / 2 && abs(y) <= layer.baseHeightMm * layer.scale / 2
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    // MARK: Interaction

    private func dragGesture(_ m: Mapping) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil { beginDrag(at: value.startLocation, m) }
                guard let drag else { return }
                switch drag {
                case .move(let id, let startX, let startY):
                    let dx = value.translation.width / m.scale, dy = value.translation.height / m.scale
                    app.updateLayer(id) {
                        $0.translateXMm = startX + dx
                        $0.translateYMm = startY + dy
                    }
                case .scale(let id, let start, let startDistance):
                    guard let layer = app.layers.first(where: { $0.id == id }), startDistance > 0 else { return }
                    let current = distance(value.location, m.point(layer.translateXMm, layer.translateYMm))
                    app.updateLayer(id) { $0.scale = max(start * current / startDistance, 0.01) }
                case .rotate(let id, let start, let startAngle):
                    guard let layer = app.layers.first(where: { $0.id == id }) else { return }
                    let center = m.point(layer.translateXMm, layer.translateYMm)
                    let angle = atan2(value.location.y - center.y, value.location.x - center.x)
                    app.updateLayer(id) { $0.rotationDeg = start + (angle - startAngle) * 180 / .pi }
                }
            }
            .onEnded { _ in drag = nil }
    }

    private func beginDrag(at point: CGPoint, _ m: Mapping) {
        if let layer = selectedLayer {
            if distance(point, rotateHandle(of: layer, m)) <= handleHitRadius {
                let center = m.point(layer.translateXMm, layer.translateYMm)
                drag = .rotate(id: layer.id, start: layer.rotationDeg, startAngle: atan2(point.y - center.y, point.x - center.x))
                return
            }
            if corners(of: layer, m).contains(where: { distance(point, $0) <= handleHitRadius }) {
                drag = .scale(id: layer.id, start: layer.scale, startDistance: distance(point, m.point(layer.translateXMm, layer.translateYMm)))
                return
            }
        }
        // Panel order is topmost-first, so this picks whatever is visually on top.
        if let hit = app.layers.first(where: { $0.visible && $0.image != nil && contains($0, point, m) }) {
            app.selectedLayerID = hit.id
            drag = .move(id: hit.id, startX: hit.translateXMm, startY: hit.translateYMm)
        }
    }
}
