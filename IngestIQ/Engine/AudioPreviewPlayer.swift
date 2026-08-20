import Foundation
import AVFoundation
import AudioToolbox
import Combine
import os.lock

/// Quick-listen playback for a selected file — lets you audibly sanity-check
/// what the classifier decided (e.g. hear L−R collapse to near-silence on a
/// true Dual Mono file, or L+R collapse on a Polarity Inverted one) without
/// leaving the app.
///
/// The whole file is decoded into memory once per selection (`load(url:)`),
/// so switching modes or seeking is instant and never re-reads from disk.
///
/// ## Why this isn't buffer-based anymore
///
/// The previous version pre-rendered a separate audio buffer per mode and
/// either restarted playback on a mode switch or crossfaded between two
/// player nodes. Both approaches kept clicking/rewinding/gurgling because
/// they were fighting the wrong problem: every mode (L, R, L+R, L−R,
/// stereo) is just a different linear combination of the *same* L/R
/// samples at the *same* playhead position. Overlapping two independently
/// rendered copies of that (the two-node crossfade) overlaps highly
/// correlated, phase-related audio — which is exactly what causes a
/// phasing/gurgling sound, the same way flanging works. And restarting
/// playback on every switch meant re-deriving "where were we" each time,
/// which is what kept causing the rewind.
///
/// This version plays the raw source continuously through a single
/// `AVAudioSourceNode` and computes each output sample live in its render
/// callback: `out = matrix * in`, where `matrix` is a small 2x2 mix that
/// differs per mode. A mode switch doesn't touch the read position or
/// restart anything — it just smoothly ramps the matrix's coefficients
/// toward the new mode's values over ~35ms, entirely within the one
/// continuous signal. There's nothing to overlap, so there's no phasing,
/// and there's no position to lose track of, so there's no rewind. A seek
/// still needs an actual jump in the source, so that one still does a
/// quick fade-out/jump/fade-in — but that's the only case where the
/// position itself changes.
final class AudioPreviewPlayer: ObservableObject {
    static let shared = AudioPreviewPlayer()

    enum Mode: String, CaseIterable, Identifiable {
        case stereo = "L ‖ R"
        case left = "L"
        case right = "R"
        case sum = "L + R"
        case diff = "L − R"
        var id: String { rawValue }
    }

    @Published private(set) var currentURL: URL?
    /// 0 = nothing loaded, 1 = mono source (mode picker is irrelevant),
    /// 2 = stereo source (all five modes apply).
    @Published private(set) var sourceChannelCount: Int = 0
    @Published var mode: Mode = .stereo {
        didSet {
            guard oldValue != mode else { return }
            guard isPlaying else { return } // not playing — the next Play() just starts in the new mode directly
            withLock {
                beginMatrixRamp(to: Self.matrix(for: mode), seconds: crossfadeSeconds)
            }
        }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTime: TimeInterval = 0
    /// Loops back to the top on reaching the end instead of stopping.
    /// Persists across file switches, like a transport setting rather than
    /// a per-file one.
    @Published var isLooping = false {
        didSet {
            guard oldValue != isLooping else { return }
            withLock { renderState.loopEnabled = isLooping }
        }
    }

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var connectedFormat: AVAudioFormat?

    /// Raw, manually-managed sample storage — read every render callback on
    /// the real-time audio thread, so it's kept as plain pointers rather
    /// than Swift Arrays to stay clear of any ARC/bridging overhead there.
    /// Only ever replaced from `load()`, and only after a synchronous
    /// `engine.stop()` (see below) guarantees the render thread isn't
    /// mid-callback when that happens.
    private var leftPtr: UnsafeMutablePointer<Float>?
    private var rightPtr: UnsafeMutablePointer<Float>?

    private var sampleRate: Double = 44_100
    private var totalFrames: Int = 0

    private var positionTimer: Timer?

    // MARK: Render-thread shared state

    /// A 2x2 mix: `outL = lFromL*inL + lFromR*inR`, `outR = rFromL*inL +
    /// rFromR*inR`. Every mode is just a different set of these four
    /// numbers over the same input samples.
    private struct MixMatrix {
        var lFromL: Float
        var lFromR: Float
        var rFromL: Float
        var rFromR: Float

        static let stereo = MixMatrix(lFromL: 1, lFromR: 0, rFromL: 0, rFromR: 1)
        static let left = MixMatrix(lFromL: 1, lFromR: 0, rFromL: 1, rFromR: 0)
        static let right = MixMatrix(lFromL: 0, lFromR: 1, rFromL: 0, rFromR: 1)
        // Half gain on sum/diff — avoids a +6dB blast when channels reinforce.
        static let sum = MixMatrix(lFromL: 0.5, lFromR: 0.5, rFromL: 0.5, rFromR: 0.5)
        static let diff = MixMatrix(lFromL: 0.5, lFromR: -0.5, rFromL: 0.5, rFromR: -0.5)
        static let zero = MixMatrix(lFromL: 0, lFromR: 0, rFromL: 0, rFromR: 0)

        static func - (a: MixMatrix, b: MixMatrix) -> MixMatrix {
            MixMatrix(lFromL: a.lFromL - b.lFromL, lFromR: a.lFromR - b.lFromR,
                      rFromL: a.rFromL - b.rFromL, rFromR: a.rFromR - b.rFromR)
        }
        static func / (a: MixMatrix, b: Float) -> MixMatrix {
            MixMatrix(lFromL: a.lFromL / b, lFromR: a.lFromR / b, rFromL: a.rFromL / b, rFromR: a.rFromR / b)
        }
    }

    private static func matrix(for mode: Mode) -> MixMatrix {
        switch mode {
        case .stereo: return .stereo
        case .left: return .left
        case .right: return .right
        case .sum: return .sum
        case .diff: return .diff
        }
    }

    /// Everything the render callback reads or writes lives here, guarded
    /// by `stateLock`. This is the only data shared between the real-time
    /// audio thread and the main thread — nothing else in this class is
    /// touched from inside `render(...)`.
    private struct RenderState {
        var isActive = false           // producing audio vs. silence
        var readFrame = 0              // next source frame to read
        var currentMatrix = MixMatrix.stereo
        var targetMatrix = MixMatrix.stereo
        var rampStep = MixMatrix.zero
        var rampFramesRemaining = 0
        var gain: Float = 0            // master fade (play-in, pause/stop-out, seek dip), 0...1
        var gainTarget: Float = 0
        var gainStep: Float = 0
        var gainStepsRemaining = 0
        var pendingStopAfterFade = false
        var pendingSeekFrame: Int?     // set by seek(); consumed by the render loop once the fade-out reaches 0
        var loopEnabled = false        // wrap to frame 0 on reaching the end instead of stopping
    }
    private var renderState = RenderState()
    private var stateLock = os_unfair_lock()

    private func withLock(_ body: () -> Void) {
        os_unfair_lock_lock(&stateLock)
        body()
        os_unfair_lock_unlock(&stateLock)
    }

    /// Must be called with `stateLock` already held.
    private func beginMatrixRamp(to target: MixMatrix, seconds: Double) {
        let frames = max(1, Int(seconds * sampleRate))
        renderState.targetMatrix = target
        renderState.rampStep = (target - renderState.currentMatrix) / Float(frames)
        renderState.rampFramesRemaining = frames
    }

    /// Must be called with `stateLock` already held.
    private func beginGainRamp(to target: Float, seconds: Double) {
        let steps = max(1, Int(seconds * sampleRate))
        renderState.gainTarget = target
        renderState.gainStep = (target - renderState.gain) / Float(steps)
        renderState.gainStepsRemaining = steps
    }

    /// Short fades: play-in, pause/stop-out, and the dip-and-jump around a
    /// seek. Long enough to kill a click, short enough to feel instant.
    private let fadeSeconds: Double = 0.015
    /// Mode-switch ramp — longer, since it's smoothing a genuine tonal
    /// change (the matrix itself), not just a level change.
    private let crossfadeSeconds: Double = 0.035

    private init() {}

    // MARK: Loading

    /// Decodes the given file into memory. Safe to call repeatedly with the
    /// same URL (no-ops if already loaded); call with a different URL (or
    /// `unload()`) whenever the table selection changes. Anything should be
    /// auditionable, not just stereo files — mono is fully supported (the
    /// mode picker just doesn't apply, so it's hidden in the UI and forced
    /// to Stereo internally, which for a mono source just plays the single
    /// channel centered).
    func load(url: URL) {
        if url == currentURL, leftPtr != nil { return }
        // Switching the selected file while something's already playing
        // should carry playback over to the new file (from its top) rather
        // than dropping back to a stopped state the user has to manually
        // resume from.
        let wasPlaying = isPlaying
        stop()

        guard let file = try? AVAudioFile(forReading: url) else {
            clearSource()
            return
        }
        let channelCount = Int(file.processingFormat.channelCount)
        guard channelCount == 1 || channelCount == 2 else {
            clearSource() // multichannel (5.1 etc.) not supported for preview
            return
        }

        let format = file.processingFormat
        let n = Int(file.length)
        guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else {
            clearSource()
            return
        }
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(n))
        } catch {
            clearSource()
            return
        }
        guard let data = buffer.floatChannelData else { clearSource(); return }

        // Synchronously halt the engine before touching leftPtr/rightPtr —
        // AVAudioEngine.stop() blocks until any in-flight render call has
        // actually finished, which is what guarantees the render thread
        // can't still be reading the old buffers at the moment we free
        // them below. The transport-level stop() above only *requests* a
        // fade (the render thread winds it down on its own schedule), so
        // it isn't enough on its own for this.
        if engine.isRunning { engine.stop() }

        freeSourceBuffers()
        let newLeft = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let newRight = UnsafeMutablePointer<Float>.allocate(capacity: n)
        newLeft.update(from: data[0], count: n)
        if channelCount == 2 {
            newRight.update(from: data[1], count: n)
        } else {
            // Mono: mirror the single channel into "right" so the render
            // callback doesn't need a separate mono code path — Stereo
            // mode then just plays that one channel centered, which is
            // what you'd want to hear anyway.
            newRight.update(from: data[0], count: n)
        }
        leftPtr = newLeft
        rightPtr = newRight

        sourceChannelCount = channelCount
        sampleRate = format.sampleRate
        totalFrames = n
        duration = sampleRate > 0 ? Double(n) / sampleRate : 0
        currentURL = url
        currentTime = 0
        if channelCount == 1 { mode = .stereo } // only mode that means anything for a mono source

        configureEngineIfNeeded()

        if wasPlaying { play() }
    }

    func unload() {
        stop()
        if engine.isRunning { engine.stop() } // see load() — same reason freeing needs the engine quiesced first
        clearSource()
    }

    private func clearSource() {
        currentURL = nil
        freeSourceBuffers()
        duration = 0; totalFrames = 0; sourceChannelCount = 0
    }

    private func freeSourceBuffers() {
        leftPtr?.deallocate()
        rightPtr?.deallocate()
        leftPtr = nil
        rightPtr = nil
    }

    deinit {
        freeSourceBuffers()
    }

    // MARK: Transport

    func play() {
        guard currentURL != nil, totalFrames > 0 else { return }
        if currentTime >= duration { currentTime = 0 }
        startPlayback(fromFrame: frame(for: currentTime))
    }

    func pause() {
        beginStopFade(resetPosition: false)
    }

    func stop() {
        beginStopFade(resetPosition: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Jumps to a new position while playing. There's only one continuous
    /// stream now, so this can't crossfade against "the old sound" the way
    /// a mode switch does — it briefly fades out, jumps the read position,
    /// and fades back in, all inside the render callback so the timing is
    /// sample-accurate rather than depending on a timer.
    func seek(to time: TimeInterval) {
        currentTime = max(0, min(duration, time))
        guard isPlaying else { return }
        let newFrame = frame(for: currentTime)
        withLock {
            renderState.pendingSeekFrame = newFrame
            beginGainRamp(to: 0.0, seconds: fadeSeconds)
        }
    }

    private func frame(for time: TimeInterval) -> Int {
        max(0, min(totalFrames, Int(time * sampleRate)))
    }

    /// Fresh start from a stopped state: snaps straight to the current
    /// mode's matrix (nothing was audible before this, so there's nothing
    /// to smooth there) and fades gain in from 0.
    private func startPlayback(fromFrame startFrame: Int) {
        guard startFrame < totalFrames else { stop(); return }
        let matrix = Self.matrix(for: mode)

        withLock {
            renderState.readFrame = startFrame
            renderState.pendingSeekFrame = nil
            renderState.pendingStopAfterFade = false
            renderState.currentMatrix = matrix
            renderState.targetMatrix = matrix
            renderState.rampFramesRemaining = 0
            renderState.gain = 0
            beginGainRamp(to: 1.0, seconds: fadeSeconds)
            renderState.isActive = true
        }

        isPlaying = true
        startPositionTimer()
    }

    private func beginStopFade(resetPosition: Bool) {
        stopPositionTimer()
        isPlaying = false
        if resetPosition { currentTime = 0 }
        withLock {
            guard renderState.isActive else { return }
            renderState.pendingSeekFrame = nil
            renderState.pendingStopAfterFade = true
            beginGainRamp(to: 0.0, seconds: fadeSeconds)
        }
    }

    // MARK: Engine / render callback

    private func configureEngineIfNeeded() {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false) else { return }

        let needsNewNode = sourceNode == nil || connectedFormat?.sampleRate != format.sampleRate
        if needsNewNode {
            if let existing = sourceNode {
                engine.disconnectNodeOutput(existing)
                engine.detach(existing)
            }
            // Strong self capture, deliberately — not weak. This runs on
            // the real-time audio thread on every render callback; a weak
            // capture requires an ARC side-table load each time, which can
            // contend with the main thread's own ARC traffic during heavy
            // allocation (e.g. opening a menu or creating a window),
            // stalling the audio thread. AudioPreviewPlayer is `.shared`
            // and never meant to deallocate, so there's no leak risk here.
            let node = AVAudioSourceNode(format: format) { [self] _, _, frameCount, audioBufferList in
                self.render(frameCount: frameCount, audioBufferList: audioBufferList)
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            sourceNode = node
            connectedFormat = format
        }

        if !engine.isRunning {
            try? engine.start()
        }
    }

    /// Runs on the real-time audio thread: no allocation, no Swift
    /// collection bridging, and the lock is only ever held for a plain
    /// struct copy in and back out — never across the sample loop itself.
    /// Reads directly from the raw sample pointers, applies the (possibly
    /// still-ramping) mix matrix and master gain per sample, and advances
    /// the read position. Reaching the end of the file is flagged back to
    /// the main thread rather than acted on directly here.
    private func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard abl.count >= 2,
              let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }
        let n = Int(frameCount)

        guard let leftPtr, let rightPtr else {
            for i in 0..<n { outL[i] = 0; outR[i] = 0 }
            return noErr
        }

        os_unfair_lock_lock(&stateLock)
        var state = renderState
        os_unfair_lock_unlock(&stateLock)

        guard state.isActive else {
            for i in 0..<n { outL[i] = 0; outR[i] = 0 }
            return noErr
        }

        var reachedEnd = false
        var stopped = false

        // Captured so the raw (pre-mix) samples this callback actually
        // reads can be handed to GoniometerBuffer in one bulk copy after
        // the loop, rather than locking that buffer once per sample below.
        let startFrame = state.readFrame
        var consumed = 0

        for i in 0..<n {
            if state.readFrame >= totalFrames {
                if state.loopEnabled {
                    // Wrap and keep going within this same callback — no
                    // silence gap, just a hard cut back to frame 0 (a click
                    // is possible if the file doesn't already loop cleanly,
                    // but that's expected for a raw audition loop, not a
                    // crossfaded one).
                    state.readFrame = 0
                } else {
                    for j in i..<n { outL[j] = 0; outR[j] = 0 }
                    state.isActive = false
                    reachedEnd = true
                    break
                }
            }

            let lv = leftPtr[state.readFrame]
            let rv = rightPtr[state.readFrame]
            state.readFrame += 1
            consumed += 1

            if state.rampFramesRemaining > 0 {
                state.currentMatrix.lFromL += state.rampStep.lFromL
                state.currentMatrix.lFromR += state.rampStep.lFromR
                state.currentMatrix.rFromL += state.rampStep.rFromL
                state.currentMatrix.rFromR += state.rampStep.rFromR
                state.rampFramesRemaining -= 1
                if state.rampFramesRemaining == 0 { state.currentMatrix = state.targetMatrix }
            }

            var l = state.currentMatrix.lFromL * lv + state.currentMatrix.lFromR * rv
            var r = state.currentMatrix.rFromL * lv + state.currentMatrix.rFromR * rv

            if state.gainStepsRemaining > 0 {
                state.gain += state.gainStep
                state.gainStepsRemaining -= 1
                if state.gainStepsRemaining == 0 {
                    state.gain = state.gainTarget
                    if let pendingSeek = state.pendingSeekFrame {
                        // Fade-out just completed — jump now (silent at
                        // this exact instant since gain is 0) and queue
                        // the fade back in.
                        state.readFrame = pendingSeek
                        state.pendingSeekFrame = nil
                        let steps = max(1, Int(fadeSeconds * sampleRate))
                        state.gain = 0
                        state.gainTarget = 1
                        state.gainStep = 1.0 / Float(steps)
                        state.gainStepsRemaining = steps
                    } else if state.pendingStopAfterFade {
                        state.isActive = false
                        stopped = true
                    }
                }
            }

            l *= state.gain
            r *= state.gain
            outL[i] = l
            outR[i] = r

            if stopped {
                for j in (i + 1)..<n { outL[j] = 0; outR[j] = 0 }
                break
            }
        }

        if consumed > 0 {
            // Raw, pre-mix samples — the goniometer always shows the
            // actual file's stereo field, regardless of which preview
            // mode (L/R/Sum/Diff) is currently selected.
            //
            // Normally startFrame..<startFrame+consumed is one contiguous
            // run in the source buffers. Looping breaks that assumption
            // when the read position wraps mid-callback — split into the
            // run before the wrap and the run after it, so this never
            // reads past the end of leftPtr/rightPtr (which are sized to
            // exactly totalFrames).
            if startFrame + consumed <= totalFrames {
                GoniometerBuffer.shared.write(sourceLeft: leftPtr, sourceRight: rightPtr, startFrame: startFrame, count: consumed)
            } else {
                let firstRun = totalFrames - startFrame
                let secondRun = consumed - firstRun
                if firstRun > 0 {
                    GoniometerBuffer.shared.write(sourceLeft: leftPtr, sourceRight: rightPtr, startFrame: startFrame, count: firstRun)
                }
                // If secondRun itself exceeds totalFrames (an extremely
                // short file wrapping more than once within a single
                // callback), skip it rather than risk an out-of-bounds
                // read — this only affects a cosmetic visualization.
                if secondRun > 0, secondRun <= totalFrames {
                    GoniometerBuffer.shared.write(sourceLeft: leftPtr, sourceRight: rightPtr, startFrame: 0, count: secondRun)
                }
            }
        }

        os_unfair_lock_lock(&stateLock)
        renderState = state
        os_unfair_lock_unlock(&stateLock)

        if reachedEnd {
            DispatchQueue.main.async { [weak self] in
                self?.handleReachedEnd()
            }
        }

        return noErr
    }

    /// Only needed for the "played to the end of the file" case — pause()
    /// and stop() already update `isPlaying`/`currentTime` synchronously on
    /// the calling thread, so there's nothing left for them to be notified
    /// of here.
    private func handleReachedEnd() {
        guard isPlaying else { return }
        isPlaying = false
        currentTime = 0
        stopPositionTimer()
    }

    // MARK: Position tracking

    /// Reads the render thread's actual position under the same lock it
    /// writes through, rather than tracking a separate wall-clock anchor —
    /// simpler, and can't drift out of sync with what's really playing.
    private func startPositionTimer() {
        stopPositionTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func tick() {
        guard isPlaying else { return }
        var frame = 0
        withLock { frame = renderState.readFrame }
        currentTime = sampleRate > 0 ? min(duration, Double(frame) / sampleRate) : 0
    }
}
