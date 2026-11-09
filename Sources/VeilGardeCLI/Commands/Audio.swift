//
//  Audio.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde audio`: the watermark on sound. `spectrogram` writes a clip's picture;
//        `sign` prints the picture's signature (vw1 text, or JSON); `match` finds where a clip (a
//        cut, a re-encode) sits on a signature, in tiles and in seconds; `verify` is match with the
//        verdict as the exit code; `roundtrip` takes the picture back to audio and reports how far
//        the sound moved; `export` cuts a mono WAV, the fixture and corpus maker; `accept` runs the
//        acceptance on a folder of clips, or on synthetic ones, and evaluates its kill criterion.
//  PIN:  Two profiles, music (44.1 kHz, 32 tile rows) and speech (16 kHz, 16 tile rows), by
//        --profile; `match` and `verify` read the profile off the signature's rows unless told. One
//        MLX workload. `accept` writes only its report and its rows; the codec's transient file is
//        deleted.
//

import ArgumentParser
import Foundation
import VeilGarde

struct AudioCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio", abstract: "Sign a clip by the warp fragility of its spectrogram picture, find a cut of it again, and take the picture back to sound.",
        discussion: "The watermark's second carrier: the picture is signed by the watermark unchanged, and nothing is written into the sound. Run `audio accept` before relying on it.",
        subcommands: [Render.self, Sign.self, Match.self, Verify.self, RoundTrip.self, Export.self, Accept.self, Phases.self])

    static func profile(named name: String) throws -> SpectrogramProfile {
        guard let profile = SpectrogramProfile.named(name) else { throw VeilGardeFailure.usage("--profile must be music or speech, not \(name)") }
        return profile
    }

    static func depth(named name: String) throws -> AudioFiles.PCMDepth {
        guard let depth = AudioFiles.PCMDepth(rawValue: name) else { throw VeilGardeFailure.usage("--depth must be int16, int24 or float32, not \(name)") }
        return depth
    }

    static func phases(_ text: String) -> [Int] { text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    struct ProfileOption: ParsableArguments {
        @Option(help: "music (44.1 kHz, 32 tile rows) or speech (16 kHz, 16 tile rows).") var profile: String = SpectrogramProfile.music.name

        func resolve() throws -> SpectrogramProfile { try AudioCommand.profile(named: profile) }
    }

    static func describe(_ clip: AudioClip, _ image: SpectrogramImage) -> String {
        String(format: "%.2f s at %.0f Hz, %d channel(s); %@ picture %d×%d px, %d×%d tiles, %d bits, floor share %.3f", clip.seconds, clip.sampleRate, clip.channelCount,
               image.profile.name, image.width, image.height, image.width / WarpConstants.tileSize, image.profile.rows,
               image.profile.bits(columns: image.width / WarpConstants.tileSize), image.floorShare)
    }

    struct Render: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "spectrogram", abstract: "Write a clip's picture as a PNG: the spectrogram the watermark signs.")
        @Argument(help: "The clip.") var audio: String
        @Option(help: "Write the PNG here.") var out: String
        @OptionGroup var profile: ProfileOption

        func run() throws {
            guarded {
                let clip = try loadClip(audio)
                let image = try AudioWatermark.picture(clip, profile: try profile.resolve())
                try image.pngData().write(to: datasetURL(out))
                note(AudioCommand.describe(clip, image))
                note("picture: \(out)")
            }
        }
    }

    struct Sign: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "sign", abstract: "Print a clip's watermark signature, read off its spectrogram picture (vw1 text, or JSON with --json).")
        @Argument(help: "The clip.") var audio: String
        @Flag(help: "JSON instead of vw1 text.") var json = false
        @OptionGroup var profile: ProfileOption

        func run() throws {
            guarded {
                let clip = try loadClip(audio)
                let image = try AudioWatermark.picture(clip, profile: try profile.resolve())
                let sig = try AudioWatermark.sign(image)
                if json { try emitJSON(try JSONCoding.prettyEncoder().encode(sig), to: "-") } else { print(sig.compact) }
                let grid = try AudioWatermark.fragility(image)
                var mean = 0.0
                for v in grid.values { mean += Double(v) }
                mean /= Double(max(1, grid.values.count))
                var variance = 0.0
                for v in grid.values { variance += (Double(v) - mean) * (Double(v) - mean) }
                variance /= Double(max(1, grid.values.count))
                note(AudioCommand.describe(clip, image))
                note(String(format: "%d×%d tiles, %d sections, %d bits, cid %@; fragility mean %.4f spread %.4f; bit balance %@", sig.rows, sig.cols, sig.codes.count,
                            sig.measuredBits, String(sig.cid.prefix(16)), mean, variance.squareRoot(),
                            sig.tileCodes.balance.map { String(format: "%.3f", $0) }.joined(separator: ", ")))
            }
        }
    }

    struct Match: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "match", abstract: "Find where a clip sits on a signature: offset in tiles and seconds, phase, score and its z-score.")
        @Argument(help: "The clip (a cut or a re-encode of a signed one).") var audio: String
        @Argument(help: "The signature: vw1 text, or a file holding vw1 text or JSON.") var signature: String
        @Option(help: "music or speech (default: the signature's own, from its tile rows).") var profile: String?
        @Option(help: "Grid phases along time in frames, comma-separated.") var phases: String = "0,8,16,24"
        @Flag(help: "JSON instead of text.") var json = false

        func run() throws {
            guarded {
                let r = try AudioWatermark.match(try loadClip(audio), against: try WatermarkCommand.signature(signature),
                                                 profile: try profile.map(AudioCommand.profile(named:)), options: MatchOptions(phases: AudioCommand.phases(phases)))
                if json { try emitJSON(try JSONCoding.prettyEncoder().encode(r), to: "-"); return }
                print(String(format: "%@: score %.4f over %d bits (z %.1f); offset %d tiles at phase %d frames, the clip's start at column %d, %.3f s into the signed clip; frequency offset %d rows",
                             r.matched ? "match" : "no match", r.result.score, r.result.bitsCompared, r.result.zScore, r.result.offsetX, r.result.phaseX, r.column, r.seconds, r.frequencyRows))
            }
        }
    }

    struct Verify: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "verify", abstract: "Exit 0 when the clip matches the signature, 1 when it does not.")
        @Argument(help: "The clip.") var audio: String
        @Argument(help: "The signature: vw1 text, or a file holding vw1 text or JSON.") var signature: String
        @Option(help: "music or speech (default: the signature's own, from its tile rows).") var profile: String?

        func run() throws {
            guarded {
                let r = try AudioWatermark.match(try loadClip(audio), against: try WatermarkCommand.signature(signature), profile: try profile.map(AudioCommand.profile(named:)))
                print(String(format: "%@ (score %.4f, %d bits, z %.1f, %.3f s)", r.matched ? "match" : "no match", r.result.score, r.result.bitsCompared, r.result.zScore, r.seconds))
                if !r.matched { throw ExitCode(1) }
            }
        }
    }

    struct RoundTrip: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "roundtrip", abstract: "Take a clip's picture back to sound, two ways, and report how far the sound moved.")
        @Argument(help: "The clip.") var audio: String
        @Option(help: "Write the reconstruction here as a WAV (the exact path, or the picture's with --from-image).") var out: String?
        @Flag(name: .customLong("from-image"), help: "Write the reconstruction from the 8-bit picture instead of the exact one.") var fromImage = false
        @Option(help: "The WAV's depth: int16, int24 or float32.") var depth: String = AudioFiles.PCMDepth.int16.rawValue
        @Flag(help: "JSON instead of text.") var json = false
        @OptionGroup var profile: ProfileOption

        struct Report: Codable {
            var profile: String
            var seconds: Double
            var frames: Int
            var exact: AudioRoundTripMetrics
            var image: AudioRoundTripMetrics
        }

        func run() throws {
            guarded {
                let p = try profile.resolve()
                let clip = try loadClip(audio)
                let signal = try AnalysisSignal(clip, profile: p)
                let exact = AudioRoundTrip.exact(signal)
                let viaImage = AudioRoundTrip.throughImage(signal)
                let report = Report(profile: p.name, seconds: signal.seconds, frames: signal.frames, exact: exact.metrics, image: viaImage.metrics)
                if json {
                    try emitJSON(try JSONCoding.prettyEncoder().encode(report), to: "-")
                } else {
                    print(String(format: "%@: %.2f s, %d frames", p.name, signal.seconds, signal.frames))
                    print(String(format: "exact path: SNR %.1f dB, max error %.2e, log-spectral deviation %.4f dB", exact.metrics.snrDB, exact.metrics.maxAbsoluteError, exact.metrics.logSpectralDeviationDB))
                    print(String(format: "image path: SNR %.1f dB, max error %.2e, log-spectral deviation %.4f dB", viaImage.metrics.snrDB, viaImage.metrics.maxAbsoluteError, viaImage.metrics.logSpectralDeviationDB))
                }
                if let out {
                    try AudioFiles.writeWAV((fromImage ? viaImage.signal : exact.signal).clip(), to: datasetURL(out), depth: try AudioCommand.depth(named: depth))
                    note("wrote the \(fromImage ? "picture's" : "exact") reconstruction: \(out)")
                }
            }
        }
    }

    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "export", abstract: "Cut a mono WAV from a clip: the fixture and corpus maker.")
        @Argument(help: "The clip.") var audio: String
        @Option(help: "Where the cut starts, in seconds.") var start: Double = 0
        @Option(help: "The cut's length in seconds (default: to the end).") var duration: Double?
        @Option(help: "Resample to this rate (default: the clip's own).") var rate: Double?
        @Option(help: "The WAV's depth: int16, int24 or float32.") var depth: String = AudioFiles.PCMDepth.int16.rawValue
        @Option(help: "Write the WAV here.") var out: String

        func run() throws {
            guarded {
                let clip = try loadClip(audio)
                let startSample = Int(start * clip.sampleRate)
                let length = duration.map { Int($0 * clip.sampleRate) } ?? (clip.frames - startSample)
                guard startSample < clip.frames, length > 0 else { throw VeilGardeFailure.usage(String(format: "the clip is %.2f s long; nothing to cut at %.2f s", clip.seconds, start)) }
                var mono = AudioTransforms.cut(clip, startSample: startSample, length: length).mono
                var outRate = clip.sampleRate
                if let rate, rate != clip.sampleRate {
                    mono = try AudioConverting.resampled(mono, from: clip.sampleRate, to: rate)
                    outRate = rate
                }
                let cut = AudioClip(sampleRate: outRate, mono: mono)
                try AudioFiles.writeWAV(cut, to: datasetURL(out), depth: try AudioCommand.depth(named: depth))
                note(String(format: "%@: %.2f s from %.2f s, mono at %.0f Hz, %@, %.1f dBFS", out, cut.seconds, start, outRate, depth, cut.rmsDBFS))
            }
        }
    }

    struct Accept: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "accept", abstract: "v1's acceptance on audio: a seeded sample of clips, cut, re-encoded, cross-matched, the kill criterion.",
            discussion: "Clips come from --audio (a folder, a text file of paths or one file, repeatable), cut into --segment seconds, or from --synthetic music-like clips.")
        @Option(help: "Audio to sample: a folder (searched recursively), a text file of paths, or a file; repeatable.") var audio: [String] = []
        @Option(help: "Instead of files: this many seeded music-like clips of 12 s.") var synthetic: Int = 0
        @Option(help: "Clips to sample.") var n: Int = 100
        @Option(help: "The sample's, the cuts' and the noise's seed.") var seed: UInt64 = 0
        @Option(help: "Cut each file into segments this long before sampling; 0 keeps whole files.") var segment: Double = 10
        @Option(help: "Grid phases along time in frames, comma-separated.") var phases: String = "0,8,16,24"
        @Option(name: .customLong("sub-hop"), help: "Also try the cut with its first fractions of a hop dropped, the best kept: 1 is the plain search, 4 tries quarters.") var subHop: Int = 1
        @Option(help: "Write the report JSON here (and the rows beside it as .rows.jsonl).") var out: String?
        @OptionGroup var profile: ProfileOption

        func run() throws {
            guarded {
                let p = try profile.resolve()
                guard subHop == 1 || subHop == 4 else { throw VeilGardeFailure.usage("--sub-hop must be 1 or 4, not \(subHop)") }
                var settings = AudioAcceptanceSettings()
                settings.seed = seed
                settings.profile = p.name
                settings.phases = AudioCommand.phases(phases)
                settings.segmentSeconds = segment
                settings.cutSubHop = subHop
                let inputs: [AudioAcceptanceInput]
                if synthetic > 0 {
                    inputs = AudioAcceptance.synthetic(count: synthetic, profile: p)
                    note("accept: \(inputs.count) synthetic clips under the \(p.name) profile")
                } else {
                    guard !audio.isEmpty else { throw VeilGardeFailure.usage("no clips: pass --audio or --synthetic") }
                    let files = try audio.flatMap { try AudioAcceptanceSample.files(in: datasetURL($0)) }
                    guard !files.isEmpty else { throw VeilGardeFailure.usage("no audio files in \(audio.joined(separator: ", "))") }
                    let items = AudioAcceptanceSample.sample(try AudioAcceptanceSample.items(for: files, segmentSeconds: segment), n: n, seed: seed)
                    note("accept: \(items.count) clips sampled from \(files.count) files under the \(p.name) profile")
                    inputs = try AudioAcceptanceSample.load(items, note: note).map {
                        AudioAcceptanceInput(path: $0.item.url.path, segment: $0.item.segment, kind: "file", clip: $0.clip)
                    }
                }
                // Each clip's row as it is measured, so a long run that stops keeps what it measured.
                let rowsURL = out.map { datasetURL($0).deletingPathExtension().appendingPathExtension("rows.jsonl") }
                let rows = try rowsURL.map { try JSONLWriter(url: $0, truncate: true) }
                let report = try AudioAcceptance.run(inputs, settings: settings, note: note, measured: { try? rows?.append($0) })
                let s = report.summary
                print(String(format: "clips %d; self-match %.1f%%; cut matched with its offset %.1f%%; AAC %d kb/s median score %.3f", s.clips, s.selfMatchRate * 100, s.cutMatchRate * 100,
                             p.aacKilobitsPerSecond, s.reencodeMedianScore))
                print(String(format: "cross-clip false matches at %.2f: %.1f%% (median cross score %.3f)", settings.threshold, s.crossFalseMatchRate * 100, s.crossMedianScore))
                if let t = s.operatingThreshold {
                    print(String(format: "operating point: threshold %.2f, cut recall %.1f%%, false matches %.1f%%", t, (s.operatingRecall ?? 0) * 100, (s.operatingFalseMatchRate ?? 0) * 100))
                }
                print("bit balance (E, S, SE, NE): " + s.bitBalance.map { String(format: "%.3f", $0) }.joined(separator: ", "))
                for (k, v) in s.speedMatchRate.sorted(by: { $0.key > $1.key }) {
                    print(String(format: "speed %@× (every %d-th clip): matched %.1f%%", k, settings.speedEvery, v * 100))
                }
                print(String(format: "measured, not gated: tile-aligned cut matched %.1f%%; gain −6 dB median %.3f; 16-bit median %.3f; noise 30 dB median %.3f; AAC decode aligned %.1f%%; frequency offsets %d; degenerate %d",
                             s.alignedCutMatchRate * 100, s.gainMedianScore, s.pcm16MedianScore, s.noiseMedianScore, s.reencodeLagZeroRate * 100, s.offsetYNonZero, s.degenerateClips))
                if subHop > 1 {
                    let offsets = Dictionary(grouping: report.clips, by: \.cutSubHopOffset).mapValues(\.count).sorted { $0.key < $1.key }
                    print("the cut's winning hop fraction, q of \(subHop): " + offsets.map { "q \($0.key): \($0.value)" }.joined(separator: ", "))
                }
                print(String(format: "round trips: exact SNR median %.1f dB; from the picture %.1f dB", s.exactSNRMedianDB, s.imageSNRMedianDB))
                print(s.killed ? "v1 audio KILLED: " + s.reasons.joined(separator: "; ") : "v1 audio passes its acceptance")
                if let out { try JSONCoding.write(report, to: datasetURL(out)); note("report: \(out)") }
            }
        }
    }

    struct Phases: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "phases", abstract: "The time-phase study: a clip's fragility dense in time, its sections' recurrences and its periodicities, against rules fixed before the run.",
            discussion: "Writes <name>.phases.json and <name>.phases.png per clip and summary.json into --out. Clips come from --audio, cut into --segment seconds, or from --synthetic clips of 12 s.")
        @Option(help: "Audio to study: a folder (searched recursively), a text file of paths, or a file; repeatable.") var audio: [String] = []
        @Option(help: "Instead of files: synthetic clips of this kind: musicLike, whiteNoise, tone or silence.") var synthetic: String?
        @Option(help: "How many synthetic clips, seeds 1 to count (tone and silence: one).") var count: Int = 5
        @Option(help: "Cut each file into segments this long before studying; 0 keeps whole files.") var segment: Double = 0
        @Option(help: "Keep only the first seconds of each clip; 0 keeps all.") var excerpt: Double = 0
        @Option(help: "Section lengths in seconds, comma-separated.") var sections: String = "0.5,1,1.5,2"
        @Option(name: .customLong("sub-hop"), help: "Columns per hop: 1, 4 or 8.") var subHop: Int = 1
        @Flag(help: "Also trace the AAC re-encode and judge the codec frame.") var aac = false
        @Option(help: "Write the reports, the figures and summary.json into this folder.") var out: String
        @OptionGroup var profile: ProfileOption

        func run() throws {
            guarded {
                let p = try profile.resolve()
                let lengths = sections.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard !lengths.isEmpty else { throw VeilGardeFailure.usage("--sections needs at least one length in seconds") }
                let folder = datasetURL(out)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var inputs: [(name: String, kind: String, clip: AudioClip)] = []
                if let synthetic {
                    guard let kind = SyntheticClips.Kind(rawValue: synthetic) else { throw VeilGardeFailure.usage("--synthetic must be musicLike, whiteNoise, tone or silence, not \(synthetic)") }
                    let n = kind == .tone || kind == .silence ? 1 : max(1, count)
                    for seed in 1...n { inputs.append(("synthetic-\(synthetic)-\(seed)", "synthetic", SyntheticClips.make(kind, seed: UInt64(seed), seconds: 12, sampleRate: p.sampleRate))) }
                } else {
                    guard !audio.isEmpty else { throw VeilGardeFailure.usage("no clips: pass --audio or --synthetic") }
                    let files = try audio.flatMap { try AudioAcceptanceSample.files(in: datasetURL($0)) }
                    guard !files.isEmpty else { throw VeilGardeFailure.usage("no audio files in \(audio.joined(separator: ", "))") }
                    let items = try AudioAcceptanceSample.items(for: files, segmentSeconds: segment > 0 ? segment : nil)
                    for (item, clip) in try AudioAcceptanceSample.load(items, note: note) {
                        let name = item.url.deletingPathExtension().lastPathComponent + (item.durationSeconds == nil ? "" : "-\(item.segment)")
                        inputs.append((name, "file", clip))
                    }
                }
                if excerpt > 0 {
                    inputs = inputs.map { ($0.name, $0.kind, AudioTransforms.cut($0.clip, startSample: 0, length: Int(excerpt * $0.clip.sampleRate))) }
                }
                note("phases: \(inputs.count) clips under the \(p.name) profile, sections \(lengths.map { String($0) }.joined(separator: ", ")) s, sub-hop \(subHop)\(aac ? ", with the AAC re-encode" : "")")
                var reports: [TimePhaseReport] = []
                for input in inputs {
                    let (report, trace) = try TimePhaseStudy.measure(input.clip, path: input.name, kind: input.kind, profile: p, sectionSeconds: lengths, subHop: subHop, reencode: aac)
                    try JSONCoding.write(report, to: folder.appendingPathComponent("\(input.name).phases.json"))
                    try TimePhaseStudy.figure(trace, t: report.periodicityT, e: report.periodicityE).write(to: folder.appendingPathComponent("\(input.name).phases.png"))
                    reports.append(report)
                    func step(_ q: Periodicity) -> String {
                        guard let d = q.dominant else { return q.flat ? "flat" : "none" }
                        return String(format: "%.1f ms (lag %d, z %.1f)", d.milliseconds, d.lag, d.z)
                    }
                    var line = String(format: "phases %@: %.1f s, %d frames; T %@; E %@; recurrences %d of %d sections", input.name, input.clip.seconds, report.frames, step(report.periodicityT),
                                      step(report.periodicityE), report.sections.reduce(0) { $0 + $1.withRecurrence }, report.sections.reduce(0) { $0 + $1.sections.count })
                    if let r = report.reencode {
                        line += String(format: "; AAC %d kb/s: codec lag %.2f, z %.1f against %.1f, frame %@", r.usedKilobitsPerSecond, r.codecLagColumns, r.zReencodeAtCodecLag, r.zOriginalAtCodecLag,
                                       report.flags.codecFrame == true ? "found" : "not found")
                    }
                    note(line + String(format: "; %.0fs", report.elapsed))
                }
                let summary = TimePhaseStudy.summarize(reports)
                try JSONCoding.write(summary, to: folder.appendingPathComponent("summary.json"))
                print("clips \(summary.clips); flat \(summary.flat); with a recurrence \(summary.withRecurrence); E's dominant step under 20 ms \(summary.stepUnder20ms)"
                      + (summary.codecFrame.map { "; codec frame found \($0) of \(summary.reencoded)" } ?? ""))
                print("E's dominant steps: " + summary.histogramE.sorted { $0.key < $1.key }.map { "\($0.key) ms: \($0.value)" }.joined(separator: ", "))
                note("reports: \(out)")
            }
        }
    }
}

/// Reads a clip through the carrier's one door.
func loadClip(_ path: String) throws -> AudioClip { try AudioFiles.read(datasetURL(path)) }
