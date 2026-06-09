//
//  AACGaplessMetadata.swift
//  myPlayer2
//
//  Reads AAC gapless metadata (encoder priming / remainder padding) so an
//  AAC→AAC gapless join can skip the encoder's leading/trailing silence instead
//  of rendering it at the boundary.
//
//  Source of truth is AudioToolbox's `kAudioFilePropertyPacketTableInfo`, which
//  CoreAudio derives from the container's gapless info — the iTunSMPB metadata
//  atom and/or the `elst` edit list for MPEG-4 / m4a. Reading the consolidated
//  packet-table value is more robust than hand-parsing iTunSMPB and matches what
//  the decoder itself uses.
//
//  This is pure, file-local work (no shared mutable state) and is intended to run
//  OFF the main actor from `AudioFilePreparationActor` during prefetch/prepare.
//

import AudioToolbox
import AVFoundation
import Foundation

/// Gapless metadata for one audio file. Frame counts are in the file's native
/// PCM sample frames (the same units as `AVAudioFile.length`), so they can be
/// compared directly against the decoded length.
struct AACGaplessInfo: Sendable {
    /// The file's data format is MPEG-4 AAC. Only AAC is trimmed; other formats
    /// (MP3 / WAV / FLAC / ALAC) report their info for diagnostics but are never
    /// trimmed by the gapless path.
    let isAAC: Bool
    /// Raw CoreAudio data-format FourCC, for logging.
    let formatID: AudioFormatID
    /// Encoder delay / priming frames at the head (decoded silence to discard).
    let primingFrames: Int64
    /// Remainder / padding frames at the tail (decoded silence to discard).
    let paddingFrames: Int64
    /// Number of valid (musical) frames per the packet table.
    let validFrames: Int64
    /// Where the values came from, for logging ("packetTable" or "none").
    let source: String

    /// True when the packet table actually provided usable gapless numbers.
    var hasGaplessPadding: Bool { source == "packetTable" && (primingFrames > 0 || paddingFrames > 0) }

    /// FourCC rendered as a readable 4-char string for logs.
    var formatTag: String { AACGaplessMetadata.fourCC(formatID) }
}

/// `nonisolated` so it can run off the main actor (the app target defaults to
/// MainActor isolation). All work is local AudioToolbox property reads.
nonisolated enum AACGaplessMetadata {

    /// Open the file with AudioToolbox and read its data format + packet-table
    /// gapless info. Returns `nil` only when the file cannot be opened at all; a
    /// non-AAC file or a file without a packet table returns a populated value
    /// with `isAAC == false` and/or `source == "none"` so callers can log a
    /// precise skip reason.
    static func read(url: URL) -> AACGaplessInfo? {
        var fileID: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID)
        guard openStatus == noErr, let fileID else { return nil }
        defer { AudioFileClose(fileID) }

        // Data format → FourCC → is this AAC?
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fmtStatus = AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &asbdSize, &asbd)
        let formatID: AudioFormatID = (fmtStatus == noErr) ? asbd.mFormatID : 0
        let isAAC = (formatID == kAudioFormatMPEG4AAC)

        // Packet table info (priming / remainder / valid frames). Unsupported for
        // WAV / AIFF and many other containers — a non-zero status just means
        // "no gapless metadata", not an error worth surfacing.
        var pti = AudioFilePacketTableInfo()
        var ptiSize = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        let ptiStatus = AudioFileGetProperty(fileID, kAudioFilePropertyPacketTableInfo, &ptiSize, &pti)

        if ptiStatus == noErr {
            return AACGaplessInfo(
                isAAC: isAAC,
                formatID: formatID,
                primingFrames: Int64(pti.mPrimingFrames),
                paddingFrames: Int64(pti.mRemainderFrames),
                validFrames: pti.mNumberValidFrames,
                source: "packetTable"
            )
        }

        return AACGaplessInfo(
            isAAC: isAAC,
            formatID: formatID,
            primingFrames: 0,
            paddingFrames: 0,
            validFrames: 0,
            source: "none"
        )
    }

    /// Render an `AudioFormatID` FourCC as a printable 4-char string (e.g.
    /// `kAudioFormatMPEG4AAC` → "aac "). Falls back to the numeric value when any
    /// byte is non-printable.
    static func fourCC(_ value: AudioFormatID) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        if bytes.allSatisfy({ (0x20...0x7E).contains($0) }) {
            return String(bytes: bytes, encoding: .ascii) ?? String(value)
        }
        return String(value)
    }
}
