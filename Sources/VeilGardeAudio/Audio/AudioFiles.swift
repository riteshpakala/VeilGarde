//
//  AudioFiles.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Door one: a file to a clip through AVAudioFile, whatever CoreAudio decodes (WAV, AIFF,
//        CAF, M4A, MP3, FLAC), its rate and length without decoding it, and a clip to a WAV file at
//        16, 24 or 32 bits.
//  PIN:  The reader every audio signature is computed through, the twin of the Lens's NSImage rule
//        (ImageDecoding): decoded as Float32, deinterleaved, at the file's own rate and channel
//        count, in chunks of 65,536 frames until the file ends. This file and AudioConverting.swift
//        are the only two that import AVFoundation (PackageLayeringTests holds it).
//

import AVFoundation
import Foundation
import VeilGardeCore

public enum AudioFiles {
    /// The file extensions the carrier reads, lowercase.
    public static let extensions: Set<String> = ["wav", "aif", "aiff", "aifc", "caf", "m4a", "mp3", "aac", "flac", "mp4"]

    public enum PCMDepth: String, Codable, Sendable, CaseIterable {
        case int16, int24, float32

        public var bits: Int {
            switch self {
            case .int16: return 16
            case .int24: return 24
            case .float32: return 32
            }
        }
    }

    public struct Info: Sendable, Equatable {
        public var sampleRate: Double
        public var channels: Int
        public var frames: Int
        public var seconds: Double { Double(frames) / sampleRate }
    }

    /// The file's rate, channel count and length, without decoding it.
    public static func info(of url: URL) throws -> Info {
        let file = try open(url)
        return Info(sampleRate: file.processingFormat.sampleRate, channels: Int(file.processingFormat.channelCount), frames: Int(file.length))
    }

    /// The whole file as a clip, at its own rate and channel count.
    public static func read(_ url: URL) throws -> AudioClip {
        let file = try open(url)
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { throw VeilGardeFailure.data("\(url.lastPathComponent) has no audio channel") }
        var channels = [[Float]](repeating: [], count: channelCount)
        let chunk: AVAudioFrameCount = 65_536
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw VeilGardeFailure.internalError("cannot allocate an audio buffer for \(url.lastPathComponent)")
            }
            do { try file.read(into: buffer, frameCount: chunk) } catch {
                throw VeilGardeFailure.data("cannot decode \(url.lastPathComponent): \(error.localizedDescription)")
            }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { throw VeilGardeFailure.internalError("\(url.lastPathComponent) decoded to no float data") }
            for c in 0..<channelCount { channels[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: n)) }
            if n < Int(chunk) { break }
        }
        guard !channels[0].isEmpty else { throw VeilGardeFailure.data("\(url.lastPathComponent) holds no audio") }
        return AudioClip(validated: format.sampleRate, channels: channels)
    }

    private static func open(_ url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw VeilGardeFailure.data("cannot read \(url.lastPathComponent) as audio: \(error.localizedDescription)")
        }
    }

    /// Writes `clip` as a WAV file at `depth`; the folder must exist.
    public static func writeWAV(_ clip: AudioClip, to url: URL, depth: PCMDepth = .int16) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: clip.sampleRate,
            AVNumberOfChannelsKey: clip.channelCount,
            AVLinearPCMBitDepthKey: depth.bits,
            AVLinearPCMIsFloatKey: depth == .float32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let buffer = try pcmBuffer(clip)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw VeilGardeFailure.data("cannot write \(url.lastPathComponent): \(error.localizedDescription)")
        }
        do { try file.write(from: buffer) } catch { throw VeilGardeFailure.data("cannot write \(url.lastPathComponent): \(error.localizedDescription)") }
        file.close()
    }

    /// `clip` as a Float32 deinterleaved buffer at its own rate, the shape every writer here takes.
    static func pcmBuffer(_ clip: AudioClip) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate, channels: AVAudioChannelCount(clip.channelCount), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, clip.frames))),
              let data = buffer.floatChannelData else {
            throw VeilGardeFailure.internalError("cannot allocate a \(clip.channelCount)-channel buffer of \(clip.frames) frames")
        }
        buffer.frameLength = AVAudioFrameCount(clip.frames)
        for (c, samples) in clip.channels.enumerated() where !samples.isEmpty {
            samples.withUnsafeBufferPointer { data[c].update(from: $0.baseAddress!, count: samples.count) }
        }
        return buffer
    }
}
