//
//  PathTracerTests.swift
//  VeilWatermarkTests
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation
import Testing
import VeilWatermark

@Suite("PathTracer")
struct PathTracerTests {
    
    @Test("chooses anchors from high-fragility regions")
    func choosesAnchorsFromHighFragility() {
        // Create a grid with known fragility values
        let rows = 8, cols = 8
        var values: [Float] = []
        for r in 0..<rows {
            for c in 0..<cols {
                // Higher fragility in top-left quadrant
                let f: Float = (r < 4 && c < 4) ? 0.8 : 0.3
                values.append(f)
            }
        }
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = PathTracer.chooseAnchors(from: grid, count: 4, minFragility: 0.5)
        
        #expect(anchors.count == 4)
        // All chosen anchors should have fragility >= 0.5
        for anchor in anchors {
            #expect(anchor.fragility >= 0.5)
        }
        // Anchors should be sorted by fragility descending
        for i in 1..<anchors.count {
            #expect(anchors[i - 1].fragility >= anchors[i].fragility)
        }
    }
    
    @Test("traces forward paths from anchors")
    func tracesForwardPaths() {
        let rows = 4, cols = 4
        let values: [Float] = Array(repeating: 0.5, count: rows * cols)
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = [PathAnchor(row: 0, col: 0, fragility: 0.5)]
        let result = PathTracer.trace(grid: grid, anchors: anchors, includeRetracing: false)
        
        #expect(result.forwardPaths.count == 1)
        let forwardPath = result.forwardPaths[0]
        #expect(forwardPath.anchor.row == 0 && forwardPath.anchor.col == 0)
        #expect(forwardPath.hints.count == rows * cols)
        #expect(forwardPath.isRetracing == false)
    }
    
    @Test("traces retracing paths back to source")
    func tracesRetracingPaths() {
        let rows = 4, cols = 4
        let values: [Float] = Array(repeating: 0.5, count: rows * cols)
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = [PathAnchor(row: 3, col: 3, fragility: 0.5)]
        let result = PathTracer.trace(grid: grid, anchors: anchors, includeRetracing: true)
        
        #expect(result.retracingPaths.count == 1)
        let retracePath = result.retracingPaths[0]
        #expect(retracePath.anchor.row == 3 && retracePath.anchor.col == 3)
        #expect(retracePath.hints.count == rows * cols)
        #expect(retracePath.isRetracing == true)
    }
    
    @Test("concatenates hints along each path")
    func concatenatesHintsAlongPath() {
        let rows = 2, cols = 2
        let values: [Float] = [0.6, 0.4, 0.5, 0.3]  // row-major
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = [PathAnchor(row: 0, col: 0, fragility: 0.6)]
        let result = PathTracer.trace(grid: grid, anchors: anchors, includeRetracing: false)
        
        let path = result.forwardPaths[0]
        #expect(path.hints.count == 4)
        
        // Each hint should have a valid direction toward the anchor
        for hint in path.hints {
            switch hint.direction {
                case .towardAnchor(let tr, let tc):
                    #expect(tr == 0 && tc == 0)
                default:
                    Issue.record("Expected towardAnchor direction")
            }
        }
    }
    
    @Test("hints encode ordinal comparisons along path direction")
    func hintsEncodeOrdinalComparisons() {
        let rows = 3, cols = 3
        // Create a grid where we know the comparison results
        var values: [Float] = []
        for r in 0..<rows {
            for c in 0..<cols {
                // Monotonically decreasing from top-left
                let f: Float = Float((rows - r) * cols + (cols - c)) / Float(rows * cols)
                values.append(f)
            }
        }
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = [PathAnchor(row: 0, col: 0, fragility: values[0])]
        let result = PathTracer.trace(grid: grid, anchors: anchors, includeRetracing: false)
        
        let path = result.forwardPaths[0]
        for hint in path.hints {
            // The hint's bits should reflect comparisons with neighbours
            // At minimum, if there are valid neighbours (mask > 0), bits should be a subset
            #expect(hint.bits & hint.mask == hint.bits)  // Bits are subset of mask
        }
    }
    
    @Test("produces anchor signatures from combined forward and retrace")
    func producesAnchorSignatures() {
        let rows = 2, cols = 2
        let values: [Float] = Array(repeating: 0.5, count: rows * cols)
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = [PathAnchor(row: 0, col: 0, fragility: 0.5)]
        let result = PathTracer.trace(grid: grid, anchors: anchors, includeRetracing: true)
        
        #expect(result.anchorSignatures.count == 1)
        let signature = result.anchorSignatures[0]
        
        // Should have forward hints + retrace hints interleaved
        let expectedCount = rows * cols * 2  // forward + retrace
        #expect(signature.count == expectedCount)
    }
    
    @Test("handles multiple anchors")
    func handlesMultipleAnchors() {
        let rows = 4, cols = 4
        let values: [Float] = Array(repeating: 0.5, count: rows * cols)
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = [
            PathAnchor(row: 0, col: 0, fragility: 0.5),
            PathAnchor(row: 0, col: 3, fragility: 0.5),
            PathAnchor(row: 3, col: 0, fragility: 0.5)
        ]
        let result = PathTracer.trace(grid: grid, anchors: anchors, includeRetracing: true)
        
        #expect(result.forwardPaths.count == 3)
        #expect(result.retracingPaths.count == 3)
        #expect(result.anchorSignatures.count == 3)
        
        // Each anchor should have its own signature
        for (i, sig) in result.anchorSignatures.enumerated() {
            #expect(!sig.isEmpty)
            // Check that the signature contains hints with the correct direction toward this anchor
            let hasTowardAnchor = sig.contains { hint in
                switch hint.direction {
                    case .towardAnchor(let tr, let tc): tr == anchors[i].row && tc == anchors[i].col
                    default: false
                }
            }
            #expect(hasTowardAnchor)
        }
    }
    
    @Test("handles edge pixels correctly")
    func handlesEdgePixels() {
        let rows = 1, cols = 4
        let values: [Float] = [0.5, 0.5, 0.5, 0.5]
        let grid = FragilityGrid(rows: rows, cols: cols, values: values, originX: 0, originY: 0)
        
        let anchors = [PathAnchor(row: 0, col: 0, fragility: 0.5)]
        let result = PathTracer.trace(grid: grid, anchors: anchors, includeRetracing: false)
        
        let path = result.forwardPaths[0]
        
        // First pixel (0,0): has east neighbour (bit 0), south-east and north-east are out of bounds
        // So mask should have bit 0 set
        #expect(path.hints[0].mask & 0b0001 != 0)  // bit 0 (east) should be set
        
        // Last pixel (0,3): no east neighbour, so mask should be 0
        let lastHint = path.hints[3]
        #expect(lastHint.mask == 0)  // No valid neighbours
    }
}
