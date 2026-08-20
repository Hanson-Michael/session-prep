import Foundation
import os.lock

/// Small ring buffer the preview player's render callback batch-writes raw
/// (pre-mix) L/R samples into once per audio callback, and GoniometerView's
/// ~30Hz display timer reads a recent window from on the main thread.
/// There's exactly one live audio stream in this app (the preview player),
/// so one shared buffer is all this ever needs — no per-file/per-view
/// instances.
///
/// Writing takes a single lock per render callback, not per sample — the
/// same "lock only around a bulk copy, never inside the sample loop"
/// discipline AudioPreviewPlayer's own render state already uses, so this
/// doesn't add per-sample overhead to the real-time audio thread.
final class GoniometerBuffer {
    static let shared = GoniometerBuffer()

    private let capacity = 8192
    private var left: UnsafeMutablePointer<Float>
    private var right: UnsafeMutablePointer<Float>
    private var writePos = 0
    private var lock = os_unfair_lock()

    private init() {
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Real-time audio thread only. `sourceLeft`/`sourceRight` point into
    /// the preview player's full decoded file; `startFrame`/`count`
    /// describe the contiguous slice this particular render callback
    /// actually consumed.
    ///
    /// Split into at most two plain contiguous runs (before/after the ring
    /// wraps) instead of computing `% capacity` on every single sample —
    /// `count` is normally far smaller than `capacity`, so this is almost
    /// always just one tight loop with no modulo at all. Cheap as this
    /// already was, it's still work done inside the real-time render
    /// callback, so it's worth not paying for a division per sample here.
    func write(sourceLeft: UnsafePointer<Float>, sourceRight: UnsafePointer<Float>, startFrame: Int, count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(&lock)

        let firstRun = min(count, capacity - writePos)
        for i in 0..<firstRun {
            left[writePos + i] = sourceLeft[startFrame + i]
            right[writePos + i] = sourceRight[startFrame + i]
        }

        let remaining = count - firstRun
        if remaining > 0 {
            for i in 0..<remaining {
                left[i] = sourceLeft[startFrame + firstRun + i]
                right[i] = sourceRight[startFrame + firstRun + i]
            }
            writePos = remaining
        } else {
            writePos += firstRun
            if writePos == capacity { writePos = 0 }
        }

        os_unfair_lock_unlock(&lock)
    }

    /// Main thread only. Returns up to `count` of the most recent samples,
    /// oldest first. Fewer than `count` come back only if playback hasn't
    /// produced that many samples yet (e.g. right after Play).
    ///
    /// The lock here is held only long enough to read the write cursor —
    /// the actual sample copy happens afterward, without it. Holding the
    /// lock across a several-thousand-sample copy would risk blocking the
    /// real-time audio thread's `write()` (which needs this same lock)
    /// for as long as that copy takes, which is exactly the kind of stall
    /// that shows up as CoreAudio "skipping cycle due to overload"
    /// warnings and audible dropouts. This buffer only ever feeds a
    /// cosmetic visualization, so the small chance of reading a sample
    /// the instant the audio thread overwrites the same slot (not a torn
    /// read — Float writes are naturally atomic at this size/alignment,
    /// so at worst one sample is a tick early/late) is a fine trade for
    /// never risking the audio thread.
    func snapshot(count: Int) -> (l: [Float], r: [Float]) {
        let n = min(count, capacity)
        guard n > 0 else { return ([], []) }

        os_unfair_lock_lock(&lock)
        let cursor = writePos
        os_unfair_lock_unlock(&lock)

        let start = (cursor - n + capacity * 4) % capacity
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let idx = (start + i) % capacity
            outL[i] = left[idx]
            outR[i] = right[idx]
        }
        return (outL, outR)
    }
}
