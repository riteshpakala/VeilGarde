//
//  SpectrogramProfile.swift
//  VeilGardeAudio
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Every constant of the picture a clip becomes, in one place: the two profiles the owner
//        fixed on 2026-11-08, music at 44.1 kHz and speech at 16 kHz, each with its FFT size and
//        hop; and what both share: the floor and ceiling in dBFS, the 255 levels, the magnitude
//        reference, the frame budget, the duration cap, and the minimum a clip needs to be admitted
//        to the acceptance.
//  PIN:  Rules fixed before any number was measured (ledger decision-139). Music: 44,100 Hz mono,
//        N 2048, hop 512, bins 1…1024, so the picture is 1024 px tall and 32 tile rows; speech:
//        16,000 Hz, N 1024, hop 256, bins 1…512, 16 tile rows. Periodic Hann, so Σw = N/2 and
//        Σw² = 3N/8, and the four overlapping copies sum to 1.5 at every interior sample. A
//        full-scale sine's peak bin is N/4, the reference for 0 dBFS; the floor is −96 dBFS. For R
//        tile rows and c columns the grid measures R(c−1) + (R−1)c + 2(R−1)(c−1) bits: 125c − 94 for
//        music, 61c − 46 for speech. The profiles are to be merged after enough research (the owner,
//        2026-11-08).
//

import Foundation
import VeilWatermark

public struct SpectrogramProfile: Sendable, Equatable, Codable {
    public let name: String
    public let sampleRate: Double
    public let fftSize: Int
    public let hop: Int
    /// The acceptance admits clips at least this long: a half cut then keeps ≥ 256 bits with margin.
    public let minimumSeconds: Double
    /// The re-encode's AAC bit rate, the JPEG q75 analog.
    public let aacKilobitsPerSecond: Int

    public static let floorDB: Double = -96
    public static let ceilingDB: Double = 0
    public static let levels = 255
    /// STFT frames evaluated per MLX call.
    public static let framesPerEval = 4096
    /// Clips longer than this are refused in v1 (memory: a 10-minute music clip is about 0.6 GB at peak).
    public static let maximumSeconds: Double = 600
    /// The acceptance skips clips quieter than this.
    public static let minimumRMSDBFS: Double = -40

    public static let music = SpectrogramProfile(name: "music", sampleRate: 44_100, fftSize: 2048, hop: 512, minimumSeconds: 4, aacKilobitsPerSecond: 128)
    public static let speech = SpectrogramProfile(name: "speech", sampleRate: 16_000, fftSize: 1024, hop: 256, minimumSeconds: 8, aacKilobitsPerSecond: 64)
    public static let all: [SpectrogramProfile] = [music, speech]

    public init(name: String, sampleRate: Double, fftSize: Int, hop: Int, minimumSeconds: Double, aacKilobitsPerSecond: Int) {
        self.name = name
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hop = hop
        self.minimumSeconds = minimumSeconds
        self.aacKilobitsPerSecond = aacKilobitsPerSecond
    }

    /// The bins the picture keeps, 1…N/2: its height in pixels.
    public var bins: Int { fftSize / 2 }
    /// Tile rows of the picture.
    public var rows: Int { bins / WarpConstants.tileSize }
    /// Zeros on each side of the signal, so every sample is covered by four frames.
    public var padding: Int { fftSize / 2 }
    /// A full-scale sine's peak bin under the periodic Hann: 0 dBFS.
    public var magnitudeReference: Double { Double(fftSize) / 4 }
    /// The periodic Hann window, built in Double (MLX's hanning is the symmetric form).
    public var window: [Double] { (0..<fftSize).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize)) } }
    public var windowSum: Double { Double(fftSize) / 2 }
    public var windowSquareSum: Double { 3 * Double(fftSize) / 8 }
    /// One tile's span in time and in frequency.
    public var tileSeconds: Double { Double(hop * WarpConstants.tileSize) / sampleRate }
    public var tileHertz: Double { sampleRate / Double(fftSize) * Double(WarpConstants.tileSize) }

    /// Frames of a signal of `samples`: 1 + ⌊samples / hop⌋ under the centre padding.
    public func frameCount(samples: Int) -> Int { samples < 0 ? 0 : 1 + samples / hop }
    /// The time a picture column stands for.
    public func seconds(column: Int) -> Double { Double(column) * Double(hop) / sampleRate }
    /// The bits a full-height grid of `columns` tile columns measures.
    public func bits(columns: Int) -> Int {
        guard columns > 0, rows > 0 else { return 0 }
        let R = rows, c = columns
        return R * (c - 1) + (R - 1) * c + 2 * (R - 1) * (c - 1)
    }

    public static func named(_ name: String) -> SpectrogramProfile? { all.first { $0.name == name } }
    /// The profile a signature was made under, from its tile rows: 32 is music, 16 is speech.
    public static func inferred(rows: Int) -> SpectrogramProfile? { all.first { $0.rows == rows } }

    /// The constants as data, for reports.
    public struct Record: Codable, Sendable, Equatable {
        public var name: String
        public var sampleRate: Double
        public var fftSize: Int
        public var hop: Int
        public var bins: Int
        public var rows: Int
        public var floorDB: Double
        public var ceilingDB: Double
        public var levels: Int
        public var minimumSeconds: Double
        public var maximumSeconds: Double
        public var aacKilobitsPerSecond: Int
    }

    public var record: Record {
        Record(name: name, sampleRate: sampleRate, fftSize: fftSize, hop: hop, bins: bins, rows: rows, floorDB: Self.floorDB, ceilingDB: Self.ceilingDB,
               levels: Self.levels, minimumSeconds: minimumSeconds, maximumSeconds: Self.maximumSeconds, aacKilobitsPerSecond: aacKilobitsPerSecond)
    }
}
