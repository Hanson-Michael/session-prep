import SwiftUI
import Combine

/// Drives the goniometer's ~30Hz redraw from GoniometerBuffer while the
/// preview player is playing, and goes blank the moment it isn't — this is
/// a sanity-check visual for whatever's currently auditioning, not a
/// running history that persists after playback stops.
final class GoniometerModel: ObservableObject {
    static let shared = GoniometerModel()

    /// Rotated + normalized to roughly ±1, oldest first. Empty means "draw
    /// nothing but the backdrop" (idle state).
    @Published private(set) var points: [CGPoint] = []

    private var timer: Timer?
    private var cancellable: AnyCancellable?
    private var norm: Float = GoniometerModel.floorNorm

    /// Raw samples pulled from GoniometerBuffer per tick — wide enough
    /// (~135ms at 44.1kHz) that a single tick's window already reads as a
    /// short trail, without needing to persist/blend bitmaps across frames.
    private static let windowSize = 6000
    /// Downsampled point count actually drawn — the window above has far
    /// more raw samples than a small on-screen trace needs.
    private static let trailPoints = 160
    private static let floorNorm: Float = 0.05
    private static let attackCoeff: Float = 0.5
    private static let releaseCoeff: Float = 0.05

    private init() {
        // .receive(on:) defers to the next run loop turn rather than
        // reacting synchronously inside $isPlaying's own willSet — without
        // it, start()/stop() below could end up publishing GoniometerModel
        // changes while SwiftUI is still mid-update from the isPlaying
        // change that triggered this in the first place ("Publishing
        // changes from within view updates is not allowed").
        cancellable = AudioPreviewPlayer.shared.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                playing ? self?.start() : self?.stop()
            }
    }

    private func start() {
        timer?.invalidate()
        norm = Self.floorNorm
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        // .default, not .common — this deliberately pauses while a menu is
        // tracking or a modal window/sheet is up, rather than competing
        // with that (and with the real-time audio thread) for CPU every
        // 33ms doing real work (buffer read, rotation math over thousands
        // of samples, array allocation). AudioPreviewPlayer's own position
        // timer uses .common safely because its tick is nearly free (one
        // lock, one field read) — this one isn't, so it shouldn't run
        // during tracking loops the way that one should. A frozen scope
        // for the second a menu is open is unnoticeable; the audio glitch
        // from it running through that moment was not.
        RunLoop.main.add(t, forMode: .default)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        points = []
    }

    private func tick() {
        let (l, r) = GoniometerBuffer.shared.snapshot(count: Self.windowSize)
        guard l.count > 1 else { points = []; return }

        var xs = [Float](); var ys = [Float]()
        xs.reserveCapacity(l.count); ys.reserveCapacity(l.count)
        var framePeak: Float = 0
        for i in 0..<l.count {
            // (R - L), not (L - R): positive x needs to mean "toward R" so
            // left-panned content renders on the left of the display.
            let x = (r[i] - l[i]) * 0.70710678
            let y = (l[i] + r[i]) * 0.70710678
            xs.append(x); ys.append(y)
            framePeak = max(framePeak, abs(x), abs(y))
        }

        // Auto-normalizing scale — fast attack so a transient doesn't clip
        // off the edge, slow release so the scale doesn't jitter tick to
        // tick.
        let target = max(framePeak, Self.floorNorm)
        norm += (target - norm) * (target > norm ? Self.attackCoeff : Self.releaseCoeff)
        norm = max(norm, Self.floorNorm)

        let stride = max(1, xs.count / Self.trailPoints)
        var sampled: [CGPoint] = []
        sampled.reserveCapacity(xs.count / stride + 1)
        var i = 0
        while i < xs.count {
            sampled.append(CGPoint(x: CGFloat(xs[i] / norm), y: CGFloat(ys[i] / norm)))
            i += stride
        }
        points = sampled
    }
}

/// 45-degree-rotated Lissajous stereo scope ("goniometer"), ported from a
/// JUCE VST plugin's Goniometer.cpp: mono content draws as a vertical
/// line, wide/decorrelated stereo spreads horizontally, out-of-phase
/// content tilts toward horizontal/inverted. Always shows the raw file's
/// L/R (see GoniometerModel/GoniometerBuffer), not whatever the preview
/// mode picker is currently doing to it.
///
/// A sanity-check visual, not the focus of the app — deliberately small
/// and fixed in size, docked to the top-right corner. Blank at rest;
/// nothing draws until the preview player is actually playing.
struct GoniometerView: View {
    @ObservedObject private var model = GoniometerModel.shared
    @ObservedObject private var settings = AppSettings.shared

    private let backdrop = Color(hex: "0b0c10")
    private let gridColor = Color(white: 0.2)
    private let size: CGFloat = 110

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            context.fill(Path(rect), with: .color(backdrop))

            let cx = canvasSize.width / 2
            let cy = canvasSize.height / 2
            let scale = min(canvasSize.width, canvasSize.height) * 0.5 * 0.86

            var crosshair = Path()
            crosshair.move(to: CGPoint(x: cx, y: 0))
            crosshair.addLine(to: CGPoint(x: cx, y: canvasSize.height))
            crosshair.move(to: CGPoint(x: 0, y: cy))
            crosshair.addLine(to: CGPoint(x: canvasSize.width, y: cy))
            context.stroke(crosshair, with: .color(gridColor), lineWidth: 1)

            for fraction: CGFloat in [0.33, 0.66, 1.0] {
                let r = scale * fraction
                let ring = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: ring), with: .color(gridColor.opacity(0.6)), lineWidth: 1)
            }

            guard model.points.count > 1 else { return }
            let traceColor = Color(hex: settings.goniometerColorHex)
            let count = model.points.count

            // Drawn as individually-faded segments (oldest = most
            // transparent) rather than one solid stroke — this is what
            // produces the fading-trail look, redrawn fresh every tick
            // rather than relying on a persistent blended bitmap.
            for i in 0..<(count - 1) {
                let p0 = model.points[i]
                let p1 = model.points[i + 1]
                let alpha = Double(i + 1) / Double(count)
                var segment = Path()
                segment.move(to: CGPoint(x: cx + p0.x * scale, y: cy - p0.y * scale))
                segment.addLine(to: CGPoint(x: cx + p1.x * scale, y: cy - p1.y * scale))
                context.stroke(segment, with: .color(traceColor.opacity(alpha)), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
