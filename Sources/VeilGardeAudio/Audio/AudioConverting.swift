//
//  AudioConverting.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Door two: a signal resampled to another rate, a clip's speed changed (the resize analog:
//        its duration scaled by a factor, its pitch by the inverse), and the AAC round trip the
//        acceptance uses as its re-encode, all through AVFoundation's converter and AVAudioFile.
//  PIN:  The resampler is AVAudioConverter at its mastering algorithm and highest quality, fed the
//        whole signal once and flushed; the output is trimmed or zero-padded to round(n · to /
//        from), so two rates always meet at one length. The AAC round trip writes a transient .m4a
//        in the temporary directory and deletes it after decoding: the one place this carrier
//        touches the disk, because AVAudioFile encodes into a container, and the container carries
//        the encoder's priming, which keeps the decode time-aligned. The lag is still measured
//        (SignalAlignment) wherever the round trip is used. The bit rate asked for is used when the
//        encoder offers it at the clip's rate and channel count, else the highest offered below it
//        (16 kHz mono stops at 48 kb/s, 22.05 kHz mono at 64), and both are reported; the rate
//        reported is the audio stream's own bytes over the clip's duration, since AVAudioFile pads
//        the container (measured 2026-11-08: 127,368 audio bytes in a 184,712-byte file).
//

import AVFoundation
import Foundation
import VeilGardeCore

public enum AudioConverting {
    /// `mono` at `from` Hz resampled to `to` Hz; identity when the rates agree.
    public static func resampled(_ mono: [Float], from: Double, to: Double) throws -> [Float] {
        guard from > 0, to > 0 else { throw VeilGardeFailure.data("sample rates must be positive, not \(from) and \(to)") }
        if from == to || mono.isEmpty { return mono }
        let expected = Int((Double(mono.count) * to / from).rounded())
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw VeilGardeFailure.internalError("no converter from \(from) Hz to \(to) Hz")
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(mono.count)), let inData = input.floatChannelData else {
            throw VeilGardeFailure.internalError("cannot allocate the resampler's input")
        }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { inData[0].update(from: $0.baseAddress!, count: mono.count) }
        var out: [Float] = []
        out.reserveCapacity(expected + 8192)
        var fed = false
        var finished = false
        while !finished {
            guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 65_536), let outData = output.floatChannelData else {
                throw VeilGardeFailure.internalError("cannot allocate the resampler's output")
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if fed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return input
            }
            if let error { throw VeilGardeFailure.internalError("resampling \(from) Hz to \(to) Hz failed: \(error.localizedDescription)") }
            out.append(contentsOf: UnsafeBufferPointer(start: outData[0], count: Int(output.frameLength)))
            switch status {
            case .haveData: finished = output.frameLength == 0
            case .inputRanDry, .endOfStream, .error: finished = true
            @unknown default: finished = true
            }
        }
        if out.count > expected { out.removeLast(out.count - expected) }
        if out.count < expected { out.append(contentsOf: [Float](repeating: 0, count: expected - out.count)) }
        return out
    }

    /// `clip` with its duration scaled by `factor` and its pitch by 1/factor: the samples declared
    /// at rate / factor and resampled back to the clip's rate, the way a resize scales a picture.
    public static func speedChanged(_ clip: AudioClip, by factor: Double) throws -> AudioClip {
        guard factor > 0 else { throw VeilGardeFailure.data("a speed factor must be positive, not \(factor)") }
        let channels = try clip.channels.map { try resampled($0, from: clip.sampleRate / factor, to: clip.sampleRate) }
        return AudioClip(validated: clip.sampleRate, channels: channels)
    }

    public struct AACRoundTrip: Sendable {
        /// The decoded clip, at the original rate and channel count.
        public var clip: AudioClip
        /// Decoded frames minus the original's.
        public var lengthDelta: Int
        /// The rate asked for, and the one the encoder was set to.
        public var requestedKilobitsPerSecond: Int
        public var usedKilobitsPerSecond: Int
        /// The audio stream's bytes over the clip's duration, in kb/s.
        public var kilobitsPerSecond: Double
    }

    /// `clip` encoded as AAC at `kilobitsPerSecond` (or the highest offered below it) into a transient .m4a and decoded back.
    public static func aacRoundTrip(_ clip: AudioClip, kilobitsPerSecond requested: Int) throws -> AACRoundTrip {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("veilgarde-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let offered = aacBitRates(sampleRate: clip.sampleRate, channels: clip.channelCount)
        let used = offered.isEmpty ? requested : (offered.filter { $0 <= requested }.max() ?? offered.min() ?? requested)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: clip.sampleRate,
            AVNumberOfChannelsKey: clip.channelCount,
            AVEncoderBitRateKey: used * 1000,
        ]
        let buffer = try AudioFiles.pcmBuffer(clip)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw VeilGardeFailure.data("no AAC encoder at \(used) kb/s for \(clip.channelCount) channel(s) at \(clip.sampleRate) Hz: \(error.localizedDescription)",
                                        hint: "offered: " + offered.map(String.init).joined(separator: ", ") + " kb/s")
        }
        do { try file.write(from: buffer) } catch { throw VeilGardeFailure.internalError("the AAC encode failed: \(error.localizedDescription)") }
        file.close()
        let bytes = audioBytes(url) ?? 0
        let decoded = try AudioFiles.read(url)
        return AACRoundTrip(clip: decoded, lengthDelta: decoded.frames - clip.frames, requestedKilobitsPerSecond: requested, usedKilobitsPerSecond: used,
                            kilobitsPerSecond: clip.seconds > 0 ? Double(bytes) * 8 / clip.seconds / 1000 : 0)
    }

    /// The AAC bit rates the encoder offers for this rate and channel count, in kb/s, ascending.
    public static func aacBitRates(sampleRate: Double, channels: Int) -> [Int] {
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                                      mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false),
              let aac = AVAudioFormat(streamDescription: &description), let converter = AVAudioConverter(from: pcm, to: aac),
              let rates = converter.applicableEncodeBitRates else { return [] }
        return rates.map { $0.intValue / 1000 }.sorted()
    }

    /// The audio stream's bytes in a file, without its container's padding.
    static func audioBytes(_ url: URL) -> Int? {
        var id: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &id) == noErr, let id else { return nil }
        defer { AudioFileClose(id) }
        var bytes: UInt64 = 0
        var size = UInt32(MemoryLayout<UInt64>.size)
        guard AudioFileGetProperty(id, kAudioFilePropertyAudioDataByteCount, &size, &bytes) == noErr else { return nil }
        return Int(bytes)
    }
}
