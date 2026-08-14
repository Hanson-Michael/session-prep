import Foundation

/// Carries session/broadcast metadata forward across every file
/// `MonoConverter` writes.
///
/// `AVAudioFile`'s writer only knows about the audio-format chunks
/// (`fmt `/`data` in a WAV, `COMM`/`SSND` in an AIFF) — it has no concept
/// of anything else a source file might carry, so without this, every
/// conversion or split would silently drop things like a WAV's BWF `bext`
/// chunk (whose `TimeReference` field is what lets a DAW auto-place a file
/// at its correct absolute position on a timeline), an `iXML` chunk from a
/// field recorder, cue/marker chunks, `LIST`/`INFO` tags (title, artist,
/// album, comment), an embedded `id3 ` chunk, or AIFF's own NAME/AUTH/
/// annotation/copyright chunks.
///
/// The approach is deliberately generic rather than a list of specific
/// chunk types to look for: read every chunk from the source *except* the
/// ones the audio writer itself owns and regenerates, and splice them,
/// completely unparsed, into the newly-written file. That way nothing gets
/// missed just because it isn't a chunk type anyone thought to name here.
///
/// Everything in this file is best-effort and non-throwing. A source or
/// destination that isn't well-formed RIFF/WAV or FORM/AIFF simply yields
/// nothing to preserve — it never blocks or fails an actual conversion.
enum BroadcastMetadata {

    // MARK: WAV / AIFF chunk preservation

    /// Chunks the audio writer already owns and regenerates correctly on
    /// its own — never duplicated or overwritten here.
    private static let wavRegeneratedChunkIDs: Set<String> = ["fmt ", "data"]
    private static let aiffRegeneratedChunkIDs: Set<String> = ["COMM", "SSND", "FVER"]

    /// Reads every chunk from `source` other than the ones the audio
    /// writer regenerates, as raw self-contained blobs (FourCC + size +
    /// payload + pad byte) ready to be spliced into a newly-written file of
    /// the same container type. Returns an empty array for anything that
    /// isn't a well-formed WAV or AIFF file — including MP3 sources, which
    /// use a completely different tag format (see `extractID3TagAsWavChunk`
    /// below).
    static func extractChunks(from source: URL) -> [Data] {
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe), data.count > 12 else { return [] }

        if data[0..<4].elementsEqual("RIFF".utf8), data[8..<12].elementsEqual("WAVE".utf8) {
            return walkChunks(in: data, bigEndian: false, skip: wavRegeneratedChunkIDs)
        }
        if data[0..<4].elementsEqual("FORM".utf8), data[8..<12].elementsEqual("AIFF".utf8) {
            return walkChunks(in: data, bigEndian: true, skip: aiffRegeneratedChunkIDs)
        }
        return []
    }

    /// Splices `chunks` (from `extractChunks`, or a single chunk from
    /// `extractID3TagAsWavChunk`) into a WAV or AIFF file that
    /// `AVAudioFile` has just finished writing at `destination`. A WAV
    /// `bext` chunk is placed first, immediately after the 12-byte
    /// container header — the BWF spec requires that position. Everything
    /// else is appended after the writer's own chunks, which is safe for
    /// chunk types without a mandated position. No-ops if `chunks` is
    /// empty or `destination` doesn't look like a well-formed WAV/AIFF.
    static func injectChunks(_ chunks: [Data], into destination: URL) {
        guard !chunks.isEmpty, let data = try? Data(contentsOf: destination), data.count > 12 else { return }

        let isWav = data[0..<4].elementsEqual("RIFF".utf8) && data[8..<12].elementsEqual("WAVE".utf8)
        let isAiff = data[0..<4].elementsEqual("FORM".utf8) && data[8..<12].elementsEqual("AIFF".utf8)
        guard isWav || isAiff else { return }

        var priority: [Data] = []
        var rest: [Data] = []
        for chunk in chunks {
            if isWav, chunkID(of: chunk) == "bext" {
                priority.append(chunk)
            } else {
                rest.append(chunk)
            }
        }

        var rebuilt = Data()
        rebuilt.append(data[0..<12]) // container header + form type, unchanged
        for chunk in priority { rebuilt.append(chunk) }
        rebuilt.append(data[12...]) // the writer's own chunks, exactly as written
        for chunk in rest { rebuilt.append(chunk) }

        let outerSize = UInt32(rebuilt.count - 8)
        rebuilt.replaceSubrange(4..<8, with: uint32Bytes(outerSize, bigEndian: isAiff))

        try? rebuilt.write(to: destination, options: .atomic)
    }

    // MARK: MP3 -> WAV tag transplant

    /// `AVAudioFile` can decode MP3 but can't encode it, so converting or
    /// splitting an MP3 source already falls back to a WAV output before
    /// any of this runs. This reads the source's ID3v2 tag block (Title/
    /// Artist/Album/etc. — it sits as a self-delimiting block at the very
    /// start of the file) and wraps it, completely unparsed, as a standard
    /// WAV `id3 ` chunk, ready for `injectChunks`. Returns nil if the
    /// source has no ID3v2 tag — the older, fixed-size ID3v1 trailer isn't
    /// handled, since it's vanishingly rare on modern files.
    static func extractID3TagAsWavChunk(from source: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: source) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 10), header.count == 10,
              header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else { return nil } // "ID3"

        // Synchsafe 32-bit size: only the low 7 bits of each of the 4 bytes are used.
        let size = Int(header[6] & 0x7F) << 21 | Int(header[7] & 0x7F) << 14
                 | Int(header[8] & 0x7F) << 7 | Int(header[9] & 0x7F)
        guard size > 0, let body = try? handle.read(upToCount: size), body.count == size else { return nil }

        var tag = header
        tag.append(body)
        return wrapAsChunk(id: "id3 ", payload: tag, bigEndian: false)
    }

    // MARK: Low-level chunk helpers

    private static func walkChunks(in data: Data, bigEndian: Bool, skip: Set<String>) -> [Data] {
        var chunks: [Data] = []
        var offset = 12
        while offset + 8 <= data.count {
            guard let id = String(data: data[offset..<(offset + 4)], encoding: .ascii) else { break }
            let size = Int(readUInt32(data, at: offset + 4, bigEndian: bigEndian))
            let payloadEnd = offset + 8 + size
            guard payloadEnd <= data.count else { break } // truncated/malformed — stop, keep what we already found
            let padded = size % 2 == 1 ? payloadEnd + 1 : payloadEnd
            let chunkEnd = min(padded, data.count)

            if !skip.contains(id) {
                chunks.append(data.subdata(in: offset..<chunkEnd))
            }
            offset = chunkEnd
        }
        return chunks
    }

    private static func wrapAsChunk(id: String, payload: Data, bigEndian: Bool) -> Data {
        var chunk = Data(id.utf8)
        chunk.append(contentsOf: uint32Bytes(UInt32(payload.count), bigEndian: bigEndian))
        chunk.append(payload)
        if payload.count % 2 == 1 { chunk.append(0) }
        return chunk
    }

    private static func chunkID(of chunk: Data) -> String? {
        guard chunk.count >= 4 else { return nil }
        return String(data: chunk.prefix(4), encoding: .ascii)
    }

    /// Manual byte-by-byte assembly rather than a typed pointer load —
    /// chunk offsets within the file aren't guaranteed to be 4-byte
    /// aligned, and this sidesteps any question of whether an unaligned
    /// load is well-defined.
    private static func readUInt32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return bigEndian ? (b0 << 24 | b1 << 16 | b2 << 8 | b3) : (b3 << 24 | b2 << 16 | b1 << 8 | b0)
    }

    private static func uint32Bytes(_ value: UInt32, bigEndian: Bool) -> [UInt8] {
        let b0 = UInt8(value & 0xFF)
        let b1 = UInt8((value >> 8) & 0xFF)
        let b2 = UInt8((value >> 16) & 0xFF)
        let b3 = UInt8((value >> 24) & 0xFF)
        return bigEndian ? [b3, b2, b1, b0] : [b0, b1, b2, b3]
    }
}
