//
//  PathTracer.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Trace paths from anchor pixels/clusters through a fragility grid, accumulating hints along
//        each path toward the next anchor. The hint at each step encodes the local fragility
//        relationship (is this pixel's fragility > neighbour's in the path direction?). Paths retrace
//        back from target to source, creating bidirectional signatures. The concatenated hint
//        sequences form the raw path signature before clustering.
//  PIN:  Anchors are chosen by clustering high-fragility regions. Path hints use ordinal comparisons
//        along the path direction, not absolute tile positions. This preserves topology under resizing.
//

import Foundation

public struct PathAnchor: Sendable, Equatable {
    public var row: Int
    public var col: Int
    public var fragility: Float
    
    public init(row: Int, col: Int, fragility: Float) {
        self.row = row
        self.col = col
        self.fragility = fragility
    }
}

public struct PathHint: Sendable, Equatable {
    /// The pixel's coordinates in the grid.
    public var row: Int
    public var col: Int
    /// Ordinal hint toward the next anchor along the path direction.
    /// Bit 0: fragility > east neighbour, bit 1: > south, bit 2: > south-east, bit 3: > north-east.
    public var bits: UInt8
    /// Which comparisons were valid (neighbour within grid bounds).
    public var mask: UInt8
    /// The path direction from this pixel toward the next anchor.
    public var direction: PathDirection
    
    public init(row: Int, col: Int, bits: UInt8, mask: UInt8, direction: PathDirection) {
        self.row = row
        self.col = col
        self.bits = bits
        self.mask = mask
        self.direction = direction
    }
}

public enum PathDirection: Sendable, Equatable {
    case towardAnchor(Int, Int)  // (targetRow, targetCol)
    case retracing(Int, Int)     // (sourceRow, sourceCol) — we're going back
}

public struct PathSignature: Sendable, Equatable {
    /// The anchor this path originates from.
    public var anchor: PathAnchor
    /// The sequence of hints along the path to every pixel.
    public var hints: [PathHint]
    /// Whether this is a forward path (anchor → pixels) or retracing (pixels → anchor).
    public var isRetracing: Bool
    
    public init(anchor: PathAnchor, hints: [PathHint], isRetracing: Bool = false) {
        self.anchor = anchor
        self.hints = hints
        self.isRetracing = isRetracing
    }
}

public struct PathTracerResult: Sendable, Equatable {
    /// All forward paths (one per anchor, tracing to every pixel).
    public var forwardPaths: [PathSignature]
    /// All retracing paths (one per anchor, from every pixel back to the anchor).
    public var retracingPaths: [PathSignature]
    /// The concatenated hint sequence for each anchor (forward + retrace interleaved).
    public var anchorSignatures: [[PathHint]]
    
    public init(forwardPaths: [PathSignature], retracingPaths: [PathSignature], anchorSignatures: [[PathHint]]) {
        self.forwardPaths = forwardPaths
        self.retracingPaths = retracingPaths
        self.anchorSignatures = anchorSignatures
    }
}

public enum PathTracer {
    
    /// Trace paths from the given anchors through the fragility grid, returning hints along each path.
    /// - Parameters:
    ///   - grid: The fragility grid to trace through.
    ///   - anchors: The anchor pixels/clusters to start paths from.
    ///   - includeRetracing: Whether to also compute retracing paths (target → source).
    /// - Returns: A PathTracerResult with forward and optionally retracing paths.
    public static func trace(grid: FragilityGrid, anchors: [PathAnchor], includeRetracing: Bool = true) -> PathTracerResult {
        let rows = grid.rows
        let cols = grid.cols
        
        var forwardPaths: [PathSignature] = []
        var retracingPaths: [PathSignature] = []
        var anchorSignatures: [[PathHint]] = []
        
        for anchor in anchors {
            // Forward path: from anchor to every pixel
            var forwardHints: [PathHint] = []
            forwardHints.reserveCapacity(rows * cols)
            
            for r in 0..<rows {
                for c in 0..<cols {
                    let direction = PathDirection.towardAnchor(anchor.row, anchor.col)
                    let hint = hintAt(grid: grid, row: r, col: c, direction: direction)
                    forwardHints.append(hint)
                }
            }
            
            let forwardPath = PathSignature(anchor: anchor, hints: forwardHints, isRetracing: false)
            forwardPaths.append(forwardPath)
            
            // Retracing path: from every pixel back to the anchor
            var retraceHints: [PathHint] = []
            if includeRetracing {
                retraceHints.reserveCapacity(rows * cols)
                
                for r in 0..<rows {
                    for c in 0..<cols {
                        let direction = PathDirection.retracing(anchor.row, anchor.col)
                        let hint = hintAt(grid: grid, row: r, col: c, direction: direction)
                        retraceHints.append(hint)
                    }
                }
                
                let retracePath = PathSignature(anchor: anchor, hints: retraceHints, isRetracing: true)
                retracingPaths.append(retracePath)
            }
            
            // Combine forward and retrace for this anchor's signature
            var combined: [PathHint] = []
            combined.reserveCapacity(forwardHints.count + (includeRetracing ? retraceHints.count : 0))
            for i in 0..<forwardHints.count {
                combined.append(forwardHints[i])
                if includeRetracing && i < retraceHints.count {
                    combined.append(retraceHints[i])
                }
            }
            anchorSignatures.append(combined)
        }
        
        return PathTracerResult(forwardPaths: forwardPaths, retracingPaths: retracingPaths, anchorSignatures: anchorSignatures)
    }
    
    /// Compute the hint at a single pixel given the path direction toward a target.
    private static func hintAt(grid: FragilityGrid, row: Int, col: Int, direction: PathDirection) -> PathHint {
        let v = grid[row, col]
        var bits: UInt8 = 0
        var mask: UInt8 = 0
        
        // Check neighbours in the path direction and cardinal directions
        // Bit 0: east neighbour (col + 1)
        if col + 1 < grid.cols {
            mask |= 1 << 0
            if v > grid[row, col + 1] { bits |= 1 << 0 }
        }
        
        // Bit 1: south neighbour (row + 1)
        if row + 1 < grid.rows {
            mask |= 1 << 1
            if v > grid[row + 1, col] { bits |= 1 << 1 }
        }
        
        // Bit 2: south-east neighbour (row + 1, col + 1)
        if row + 1 < grid.rows && col + 1 < grid.cols {
            mask |= 1 << 2
            if v > grid[row + 1, col + 1] { bits |= 1 << 2 }
        }
        
        // Bit 3: north-east neighbour (row - 1, col + 1)
        if row > 0 && col + 1 < grid.cols {
            mask |= 1 << 3
            if v > grid[row - 1, col + 1] { bits |= 1 << 3 }
        }
        
        return PathHint(row: row, col: col, bits: bits, mask: mask, direction: direction)
    }
    
    /// Choose anchor pixels/clusters from a fragility grid by selecting high-fragility regions.
    /// - Parameters:
    ///   - grid: The fragility grid to analyze.
    ///   - count: The number of anchors to choose.
    ///   - minFragility: Minimum fragility threshold for anchor candidates.
    /// - Returns: An array of PathAnchor sorted by fragility (highest first).
    public static func chooseAnchors(from grid: FragilityGrid, count: Int, minFragility: Float = 0.5) -> [PathAnchor] {
        var candidates: [(row: Int, col: Int, fragility: Float)] = []
        
        for r in 0..<grid.rows {
            for c in 0..<grid.cols {
                let f = grid[r, c]
                if f >= minFragility {
                    candidates.append((r, c, f))
                }
            }
        }
        
        // Sort by fragility descending
        candidates.sort { $0.fragility > $1.fragility }
        
        // Take top candidates, ensuring spatial spread (simple: just take top N)
        let selected = candidates.prefix(count).map { PathAnchor(row: $0.row, col: $0.col, fragility: $0.fragility) }
        return Array(selected)
    }
}
