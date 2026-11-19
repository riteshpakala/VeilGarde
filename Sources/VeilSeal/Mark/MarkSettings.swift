//
//  MarkSettings.swift
//  VeilSeal
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The knobs of the pixel mark: how far a pixel may move and how the optimiser moves it
//        (MarkSettings), how a reading searches for the period (MarkReadOptions), and what an embed
//        reports while it runs (MarkProgress).
//  PIN:  The defaults are the plan's starting point, not a measured optimum: a probe tunes the bound,
//        the update smoothing and the shift term on a seeded sample, and the person signs off the
//        defaults before an acceptance run measures them against bars fixed in advance. A
//        change here changes every later mark's look and strength, never how an earlier one reads.
//  PIN:  THE SHIFT TERM STARTS OFF (2026-11-17). On the 1024² composite it left the tile error at the
//        exact phase where it was (0.19 against 0.19 off) and cost a quarter of the embed's time; a read
//        1 px off on both axes sees nothing either way, so the reader searches every phase instead.
//        Margins of 0.35, 0.7 and 1.2 read alike too: the per-pixel bound, not the objective, is what
//        holds the mark's strength.
//  PIN:  SIGNED OFF (2026-11-17, decision-153). The owner took these defaults as they stand, before
//        the probe ran, so integrations test against fixed knobs; the acceptance run and its bars stay
//        open, and a default moves again only on the owner's word.
//

import Foundation

public struct MarkSettings: Codable, Sendable, Equatable {
    /// The most a pixel's luma may move, in levels (the per-pixel bound is min(this, 3·σ₇/8), at least 1).
    public var bound: Int
    /// σ of the Gaussian that smooths each step's update field; 0 leaves it per pixel.
    public var smoothing: Double
    /// Also optimise at one random grid shift within ±`shiftRadius` px each step, so a reading a few
    /// pixels off still sees the levels.
    public var shiftTerm: Bool
    public var shiftRadius: Int
    public var steps: Int
    /// The log-fragility gap a pair of differing levels is pushed to, on the embedding grid.
    public var margin: Float
    /// The same at the random shift, and that term's weight.
    public var shiftMargin: Float
    public var shiftWeight: Float
    /// The softplus's sharpness, per unit of log fragility.
    public var sharpness: Float
    /// After this many steps, pairs still short by more than `dropFactor` margins leave the objective:
    /// the code absorbs them.
    public var dropAfter: Int
    public var dropFactor: Float
    /// Rounds of extra steps when the marked PNG does not read back, and steps per round.
    public var repairRounds: Int
    public var repairSteps: Int
    /// Seeds the random shifts, so an embed is repeatable up to MLX's gradient rounding.
    public var seed: UInt64
    /// Mark an image that already carries a mark (refused otherwise).
    public var force: Bool

    public init(bound: Int = 3, smoothing: Double = 0, shiftTerm: Bool = false, shiftRadius: Int = 4, steps: Int = 20,
                margin: Float = 0.35, shiftMargin: Float = 0.175, shiftWeight: Float = 0.25, sharpness: Float = 10,
                dropAfter: Int = 5, dropFactor: Float = 3, repairRounds: Int = 2, repairSteps: Int = 6, seed: UInt64 = 0, force: Bool = false) {
        self.bound = bound
        self.smoothing = smoothing
        self.shiftTerm = shiftTerm
        self.shiftRadius = shiftRadius
        self.steps = steps
        self.margin = margin
        self.shiftMargin = shiftMargin
        self.shiftWeight = shiftWeight
        self.sharpness = sharpness
        self.dropAfter = dropAfter
        self.dropFactor = dropFactor
        self.repairRounds = repairRounds
        self.repairSteps = repairSteps
        self.seed = seed
        self.force = force
    }

    public static let `default` = MarkSettings()
}

public struct MarkReadOptions: Codable, Sendable, Equatable {
    /// The most tiles the reading at a found phase reads, from the image's centre: each period more folded in is a
    /// quieter read of the same bits.
    public var windowTiles: Int
    /// The most tiles each read of the phase search reads, from the image's centre.
    public var searchTiles: Int
    /// Whether a reading that finds nothing at phase (0, 0) searches every phase (a crop's grid can sit anywhere).
    /// Off, it reads where an uncropped image keeps its mark and nowhere else: an embed's own checks.
    public var search: Bool
    /// The pilots' z-score a reading needs, on top of the CRC.
    public var pilotThreshold: Double
    /// The most one neighbour's log-fragility difference counts toward a tile's soft level, either way.
    public var clamp: Float

    public init(windowTiles: Int = 4096, searchTiles: Int = 640, search: Bool = true, pilotThreshold: Double = 3, clamp: Float = 2) {
        self.windowTiles = windowTiles
        self.searchTiles = searchTiles
        self.search = search
        self.pilotThreshold = pilotThreshold
        self.clamp = clamp
    }

    public static let `default` = MarkReadOptions()
    /// Phase (0, 0) only: where an image marked whole keeps its mark.
    public static let unsearched = MarkReadOptions(search: false)
}

/// Where an embed is, for a progress line.
public struct MarkProgress: Sendable, Equatable {
    public enum Stage: String, Sendable, Codable {
        case checking, embedding, verifying, repairing, signing
    }

    public var stage: Stage
    public var step: Int
    public var steps: Int
    /// The objective on the embedding grid, and the share of its pairs that hold their margin.
    public var loss: Float
    public var satisfied: Double
    public var seconds: Double

    public init(stage: Stage, step: Int = 0, steps: Int = 0, loss: Float = 0, satisfied: Double = 0, seconds: Double = 0) {
        self.stage = stage
        self.step = step
        self.steps = steps
        self.loss = loss
        self.satisfied = satisfied
        self.seconds = seconds
    }

    /// "embedding · step 7/20 · 83% of pairs".
    public var line: String {
        switch stage {
        case .embedding, .repairing:
            return "\(stage.rawValue) · step \(step)/\(steps) · \(Int((satisfied * 100).rounded()))% of pairs"
        default:
            return stage.rawValue
        }
    }
}
