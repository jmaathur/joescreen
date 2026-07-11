import SwiftUI
import Observation
import JoeScreenKit

/// Observable holder for the replicated ink of ALL windows (F9). The DrawPump mutates the model via
/// `apply`; the overlay views observe. One shared instance lives on AppModel.
@MainActor
@Observable
final class DrawState {
    /// The replicated annotation store (convergent by construction — see DrawModel).
    private(set) var model = DrawModel()
    /// Whether the local user is in DRAW mode (captures strokes vs. passes hover through).
    var drawModeEnabled = false
    /// A rev counter bumped on every apply so SwiftUI re-renders the Canvas (DrawModel is a value type).
    private(set) var rev: Int = 0

    func apply(_ mutation: (inout DrawModel) -> Void) {
        mutation(&model)
        rev &+= 1
    }

    func reset() { model = DrawModel(); rev &+= 1; drawModeEnabled = false }
}

/// A SwiftUI `Canvas` ink overlay drawn over a remote window's video (F9). Renders every
/// participant's strokes in their color; in draw mode, captures the local user's drag as a stroke
/// and hands it to `onStroke` (normalized to the video content rect via VideoFitMath, so ink lands
/// on the same pixel feature at every peer). Click-through when NOT in draw mode.
struct DrawOverlay: View {
    let windowID: WindowID
    let size: CGSize
    let videoAspect: Double?
    @Environment(DrawState.self) private var draw
    @Environment(AppModel.self) private var model

    /// In-progress local stroke (view-space points), drawn live before it's committed.
    @State private var current: [CGPoint] = []

    var body: some View {
        Canvas { ctx, canvasSize in
            _ = draw.rev // observe → re-render on any apply
            // Committed strokes (all authors).
            for op in draw.model.strokes(in: windowID) {
                var path = Path()
                let pts = op.points.map { VideoFitMath.viewPoint(fromNormalized: $0, videoAspect: aspect(canvasSize), viewSize: canvasSize) }
                if let first = pts.first {
                    path.move(to: first)
                    for p in pts.dropFirst() { path.addLine(to: p) }
                }
                ctx.stroke(path, with: .color(Color(red: op.color.r, green: op.color.g, blue: op.color.b, opacity: op.color.a)),
                           style: StrokeStyle(lineWidth: op.width, lineCap: .round, lineJoin: .round))
            }
            // The in-progress local stroke.
            if current.count > 1 {
                var path = Path()
                path.move(to: current[0])
                for p in current.dropFirst() { path.addLine(to: p) }
                ctx.stroke(path, with: .color(model.color(for: model.localParticipantID ?? windowID)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
        .allowsHitTesting(draw.drawModeEnabled)
        .gesture(draw.drawModeEnabled ? drawGesture : nil)
    }

    private func aspect(_ canvasSize: CGSize) -> Double {
        videoAspect ?? Double(canvasSize.width / max(canvasSize.height, 1))
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in current.append(v.location) }
            .onEnded { _ in
                let normalized = current.map {
                    VideoFitMath.normalizedPoint(fromViewPoint: $0, videoAspect: aspect(size), viewSize: size)
                }
                current = []
                guard normalized.count > 1 else { return }
                model.sendStroke(windowID: windowID, points: normalized)
            }
    }
}

/// The per-window draw toolbar (F9): toggle draw mode, undo the local author's last stroke, clear
/// the local author's ink. Bottom-right, non-obtrusive.
struct DrawToolbar: View {
    let windowID: WindowID
    @Environment(DrawState.self) private var draw
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    button("pencil.tip.crop.circle\(draw.drawModeEnabled ? ".fill" : "")",
                           on: draw.drawModeEnabled) { model.toggleDrawMode() }
                    button("arrow.uturn.backward") { model.undoDraw(windowID: windowID) }
                    button("trash") { model.clearDraw(windowID: windowID) }
                }
                .padding(6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(10)
            }
        }
    }

    private func button(_ systemImage: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(on ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
