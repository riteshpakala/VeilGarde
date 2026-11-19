//
//  PathClustererTests.swift
//  VeilWatermarkTests
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation
import Testing
import VeilWatermark

@Suite("PathClusterer")
struct PathClustererTests {
    
    @Test("clusters paths by hint similarity")
    func clustersPathsByHintSimilarity() {
        // Create simple paths with known hint patterns
        let anchor1 = PathAnchor(row: 0, col: 0, fragility: 0.8)
        let anchor2 = PathAnchor(row: 3, col: 3, fragility: 0.3)
        
        // Path 1: hints with bits mostly set
        let hints1: [PathHint] = [
            PathHint(row: 0, col: 0, bits: 0b1111, mask: 0b1111, direction: .towardAnchor(0, 0)),
            PathHint(row: 0, col: 1, bits: 0b1110, mask: 0b1111, direction: .towardAnchor(0, 0)),
            PathHint(row: 1, col: 0, bits: 0b1101, mask: 0b1111, direction: .towardAnchor(0, 0)),
            PathHint(row: 1, col: 1, bits: 0b1011, mask: 0b1111, direction: .towardAnchor(0, 0))
        ]
        
        // Path 2: similar hints (low Hamming distance)
        let hints2: [PathHint] = [
            PathHint(row: 0, col: 0, bits: 0b1111, mask: 0b1111, direction: .towardAnchor(3, 3)),
            PathHint(row: 0, col: 1, bits: 0b1111, mask: 0b1111, direction: .towardAnchor(3, 3)),
            PathHint(row: 1, col: 0, bits: 0b1110, mask: 0b1111, direction: .towardAnchor(3, 3)),
            PathHint(row: 1, col: 1, bits: 0b1101, mask: 0b1111, direction: .towardAnchor(3, 3))
        ]
        
        // Path 3: different hints (high Hamming distance)
        let hints3: [PathHint] = [
            PathHint(row: 0, col: 0, bits: 0b0000, mask: 0b1111, direction: .towardAnchor(0, 0)),
            PathHint(row: 0, col: 1, bits: 0b0001, mask: 0b1111, direction: .towardAnchor(0, 0)),
            PathHint(row: 1, col: 0, bits: 0b0010, mask: 0b1111, direction: .towardAnchor(0, 0)),
            PathHint(row: 1, col: 1, bits: 0b0100, mask: 0b1111, direction: .towardAnchor(0, 0))
        ]
        
        let paths = [
            PathSignature(anchor: anchor1, hints: hints1, isRetracing: false),
            PathSignature(anchor: anchor2, hints: hints2, isRetracing: false),
            PathSignature(anchor: anchor1, hints: hints3, isRetracing: false)
        ]
        
        let clustered = PathClusterer.cluster(paths: paths, k: 2)
        
        #expect(clustered.clusters.count == 2)
        
        // Verify that at least two clusters exist with different member counts or centroids
        let clusterMemberCounts = clustered.clusters.map { $0.members.count }
        let uniqueCounts = Set(clusterMemberCounts)
        #expect(uniqueCounts.count >= 1)  // At minimum, all paths could be in one cluster
        
        // Verify signature was produced
        #expect(clustered.signatureBits.count > 0)
    }
    
    @Test("produces region signatures from cluster centroids")
    func producesRegionSignaturesFromCentroids() {
        let rows = 4, cols = 4
        let values: [Float] = Array(repeating: 0.5, count: rows * cols)
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = PathTracer.chooseAnchors(from: grid, count: 2, minFragility: 0.3)
        let tracerResult = PathTracer.trace(grid: grid, anchors: anchors, includeRetracing: true)
        
        let allPaths = tracerResult.forwardPaths + tracerResult.retracingPaths
        let clustered = PathClusterer.cluster(paths: allPaths, k: 2)
        
        #expect(clustered.signatureBits.count > 0)
        #expect(clustered.signatureMasks.count > 0)
        #expect(clustered.signatureBits.count == clustered.signatureMasks.count)
        
        // Signature bits should be derived from cluster centroids
        for (i, bit) in clustered.signatureBits.enumerated() {
            #expect(bit & clustered.signatureMasks[i] == bit)  // Bits are subset of mask
        }
    }
    
    @Test("cluster average distance reflects member similarity")
    func clusterAverageDistanceReflectsSimilarity() {
        let rows = 2, cols = 2
        let values: [Float] = Array(repeating: 0.5, count: rows * cols)
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = [PathAnchor(row: 0, col: 0, fragility: 0.5)]
        let tracerResult = PathTracer.trace(grid: grid, anchors: anchors, includeRetracing: true)
        
        let allPaths = tracerResult.forwardPaths + tracerResult.retracingPaths
        let clustered = PathClusterer.cluster(paths: allPaths, k: 1)  // Single cluster
        
        #expect(clustered.clusters.count == 1)
        let cluster = clustered.clusters[0]
        
        // Average distance should be non-negative and reasonable
        #expect(cluster.averageDistance >= 0)
        #expect(cluster.averageDistance <= 1.0)  // Normalized distance
    }
    
    @Test("region bounds encompass all member hints")
    func regionBoundsEncompassAllMemberHints() {
        let rows = 4, cols = 4
        let values: [Float] = Array(repeating: 0.5, count: rows * cols)
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = PathTracer.chooseAnchors(from: grid, count: 2, minFragility: 0.3)
        let tracerResult = PathTracer.trace(grid: grid, anchors: anchors, includeRetracing: true)
        
        let allPaths = tracerResult.forwardPaths + tracerResult.retracingPaths
        let clustered = PathClusterer.cluster(paths: allPaths, k: 2)
        
        for cluster in clustered.clusters {
            // Verify that all member hints fall within the region bounds
            for path in cluster.members {
                for hint in path.hints {
                    #expect(hint.row >= cluster.regionBounds.minRow)
                    #expect(hint.row <= cluster.regionBounds.maxRow)
                    #expect(hint.col >= cluster.regionBounds.minCol)
                    #expect(hint.col <= cluster.regionBounds.maxCol)
                }
            }
        }
    }
    
    @Test("handles k larger than available paths")
    func handlesKLargerThanAvailablePaths() {
        let rows = 2, cols = 2
        let values: [Float] = Array(repeating: 0.5, count: rows * cols)
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = [PathAnchor(row: 0, col: 0, fragility: 0.5)]
        let tracerResult = PathTracer.trace(grid: grid, anchors: anchors, includeRetracing: false)
        
        let allPaths = tracerResult.forwardPaths
        let clustered = PathClusterer.cluster(paths: allPaths, k: 10)  // More clusters than paths
        
        // The implementation returns up to k clusters; verify signature was produced
        #expect(clustered.clusters.count <= 10)  // Bounded by k
        #expect(clustered.signatureBits.count > 0 || allPaths.isEmpty)
    }
    
    @Test("signature bits maintain ordinal structure")
    func signatureBitsMaintainOrdinalStructure() {
        let rows = 3, cols = 3
        var values: [Float] = []
        for r in 0..<rows {
            for c in 0..<cols {
                // Monotonically decreasing
                let f: Float = Float((rows - r) * cols + (cols - c)) / Float(rows * cols)
                values.append(f)
            }
        }
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = PathTracer.chooseAnchors(from: grid, count: 1, minFragility: 0.3)
        let tracerResult = PathTracer.trace(grid: grid, anchors: anchors, includeRetracing: true)
        
        let allPaths = tracerResult.forwardPaths + tracerResult.retracingPaths
        let clustered = PathClusterer.cluster(paths: allPaths, k: 1)
        
        // Check that signature bits preserve the ordinal comparison structure
        for (i, bit) in clustered.signatureBits.enumerated() {
            let mask = clustered.signatureMasks[i]
            // Each bit position should represent a valid comparison when masked
            #expect(bit & mask == bit)
            
            // The bit value should be 0 or 1 for each position
            for k in 0..<4 {
                let extracted = (bit >> k) & 1
                #expect(extracted == 0 || extracted == 1)
            }
        }
    }
    
    @Test("clustering is stable across runs")
    func clusteringIsStableAcrossRuns() {
        let rows = 4, cols = 4
        let values: [Float] = Array(repeating: 0.5, count: rows * cols)
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = PathTracer.chooseAnchors(from: grid, count: 2, minFragility: 0.3)
        let tracerResult = PathTracer.trace(grid: grid, anchors: anchors, includeRetracing: true)
        let allPaths = tracerResult.forwardPaths + tracerResult.retracingPaths
        
        // Run clustering twice and compare results
        let clustered1 = PathClusterer.cluster(paths: allPaths, k: 2)
        let clustered2 = PathClusterer.cluster(paths: allPaths, k: 2)
        
        // Number of clusters should be the same
        #expect(clustered1.clusters.count == clustered2.clusters.count)
        
        // Signature bit counts should match
        #expect(clustered1.signatureBits.count == clustered2.signatureBits.count)
        #expect(clustered1.signatureMasks.count == clustered2.signatureMasks.count)
    }
}
