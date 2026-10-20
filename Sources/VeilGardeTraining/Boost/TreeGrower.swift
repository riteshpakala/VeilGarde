//
//  TreeGrower.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Grows one regression tree on gradient statistics, level by level, the way XGBoost's
//        `hist` updater does with the depthwise policy: per-node gradient histograms over the
//        quantized bins, the best split per node, children allocated in node order.
//  PIN:  XGBoost's arithmetic, step for step: histograms sum Float gradients in Double; a child's
//        gain is G²/(H+λ) cast to Float, the split's loss change is (gainL + gainR) − gainParent in
//        Float; a candidate needs both children's hessian ≥ min_child_weight; a node splits when
//        the loss change is > 1e-6 and ≥ γ, both sides hold hessian, and depth < max_depth; ties go
//        to the lower feature, then the lower bin (a later candidate must be strictly better).
//        Weights are −G/(H+λ) (0 when H < min_child_weight), leaves are Float(weight)·Float(η).
//        Missing values sit in the last bin and so always go right (default_left = 0), which is
//        what the evaluator does with NaN. The child with the larger hessian sum takes the parent's
//        histogram minus its sibling's (the subtraction trick, XGBoost's choice of sibling). Parallel work writes disjoint slices and every
//        reduction runs in a fixed order, so a tree is the same on every run.
//

import Foundation
import VeilGardeCore

struct TreeGrower {
    static let binStride = 256

    let matrix: BinMatrix
    let params: BoostParams
    /// This tree's column sample, ascending.
    let features: [Int]

    struct Grown {
        var tree: GBDTModel.Tree
        /// Per node: the split bin (rows with bin ≤ it go left), −1 at a leaf.
        var splitBins: [Int32]
    }

    private struct Stats { var g: Double; var h: Double }

    private struct Split {
        var loss: Float = 0
        var slot = -1
        var bin = -1
        var left = Stats(g: 0, h: 0)
        var right = Stats(g: 0, h: 0)
    }

    private struct Node {
        var rows: [Int32]
        var stats: Stats
        var depth: Int
        var nid: Int
        var histogram: Int        // index into the level's histogram set
    }

    func grow(id: Int, rows: [Int32], gradients g: [Float], hessians h: [Float]) -> Grown {
        let lambda = params.lambda, mcw = params.minChildWeight
        let eta = Float(params.eta)

        var left: [Int32] = [-1], right: [Int32] = [-1], parents: [Int32] = [GBDTModel.Tree.rootParent]
        var splitIndex: [Int32] = [0], conditions: [Float] = [0], baseWeights: [Float] = [0]
        var lossChanges: [Float] = [0], sumHessian: [Float] = [0], splitBins: [Int32] = [-1]

        func weight(_ s: Stats) -> Float {
            if s.h < mcw || s.h <= 0 { return 0 }
            return Float(-s.g / (s.h + lambda))
        }
        func gain(_ s: Stats) -> Float {
            if s.h <= 0 { return 0 }
            return Float(s.g * s.g / (s.h + lambda))
        }

        // The root: its histogram, its totals summed from the first sampled feature's bins.
        var level = buildHistograms([rows])
        var rootStats = Stats(g: 0, h: 0)
        if !features.isEmpty {
            let nb = matrix.cuts[features[0]].count + 1
            for b in 0..<nb { rootStats.g += level[2 * b]; rootStats.h += level[2 * b + 1] }
        } else {
            for r in rows { rootStats.g += Double(g[Int(r)]); rootStats.h += Double(h[Int(r)]) }
        }
        // A lone root is a leaf holding the η-scaled weight.
        let rootWeight = weight(rootStats)
        conditions[0] = rootWeight * eta
        baseWeights[0] = rootWeight * eta
        sumHessian[0] = Float(rootStats.h)

        var nodes = [Node(rows: rows, stats: rootStats, depth: 0, nid: 0, histogram: 0)]
        while !nodes.isEmpty {
            let splits = evaluate(nodes, histograms: level, gain: gain)
            var children: [Node] = []
            var built: [[Int32]] = []          // per split, the child built directly
            var derived: [(parent: Int, built: Int, isLeftBuilt: Bool)] = []
            for (k, node) in nodes.enumerated() {
                let s = splits[k]
                guard s.slot >= 0, s.loss > 1e-6, s.loss >= Float(params.gamma), s.left.h != 0, s.right.h != 0,
                      node.depth < params.maxDepth else { continue }
                let f = features[s.slot]
                let nid = node.nid
                let l = left.count, r = l + 1
                // The node becomes internal.
                left[nid] = Int32(l); right[nid] = Int32(r)
                splitIndex[nid] = Int32(f)
                conditions[nid] = matrix.cuts[f][s.bin]
                baseWeights[nid] = weight(node.stats)
                lossChanges[nid] = s.loss
                sumHessian[nid] = Float(node.stats.h)
                splitBins[nid] = Int32(s.bin)
                // Its children are leaves until they split.
                let wl = weight(s.left) * eta, wr = weight(s.right) * eta
                left += [-1, -1]; right += [-1, -1]; parents += [Int32(nid), Int32(nid)]
                splitIndex += [0, 0]; conditions += [wl, wr]; baseWeights += [wl, wr]
                lossChanges += [0, 0]; sumHessian += [Float(s.left.h), Float(s.right.h)]; splitBins += [-1, -1]

                if node.depth + 1 >= params.maxDepth { continue }   // children cannot split: no histograms
                let column = f
                let cut = UInt8(truncatingIfNeeded: s.bin)
                var lrows: [Int32] = [], rrows: [Int32] = []
                lrows.reserveCapacity(node.rows.count / 2); rrows.reserveCapacity(node.rows.count / 2)
                matrix.bins.withUnsafeBufferPointer { bins in
                    let base = column * matrix.rows
                    for row in node.rows {
                        if bins[base + Int(row)] <= cut { lrows.append(row) } else { rrows.append(row) }
                    }
                }
                // XGBoost builds the child with the smaller hessian sum (ties: the left).
                let buildLeft = !(s.right.h < s.left.h)
                derived.append((parent: node.histogram, built: built.count, isLeftBuilt: buildLeft))
                built.append(buildLeft ? lrows : rrows)
                children.append(Node(rows: lrows, stats: s.left, depth: node.depth + 1, nid: l, histogram: -1))
                children.append(Node(rows: rrows, stats: s.right, depth: node.depth + 1, nid: r, histogram: -1))
            }
            if children.isEmpty { break }
            // The next level's histograms: one child built, its sibling derived.
            let direct = buildHistograms(built)
            let width = features.count * Self.binStride * 2
            var next = [Double](repeating: 0, count: children.count * width)
            next.withUnsafeMutableBufferPointer { out in
                direct.withUnsafeBufferPointer { d in
                    level.withUnsafeBufferPointer { p in
                        for (pair, link) in derived.enumerated() {
                            let builtSlot = link.isLeftBuilt ? 2 * pair : 2 * pair + 1
                            let otherSlot = link.isLeftBuilt ? 2 * pair + 1 : 2 * pair
                            let src = link.built * width, par = link.parent * width
                            for i in 0..<width {
                                out[builtSlot * width + i] = d[src + i]
                                out[otherSlot * width + i] = p[par + i] - d[src + i]
                            }
                        }
                    }
                }
            }
            for i in children.indices { children[i].histogram = i }
            level = next
            nodes = children
        }

        let count = left.count
        let tree = GBDTModel.Tree(id: id, leftChildren: left, rightChildren: right, parents: parents, splitIndices: splitIndex,
                                  splitConditions: conditions, baseWeights: baseWeights,
                                  defaultLeft: [Int](repeating: 0, count: count), splitType: [Int](repeating: 0, count: count),
                                  lossChanges: lossChanges, sumHessian: sumHessian, numFeature: matrix.features)
        return Grown(tree: tree, splitBins: splitBins)

        // MARK: Local helpers (closures over g and h)

        func buildHistograms(_ sets: [[Int32]]) -> [Double] {
            let slots = features.count
            let width = slots * Self.binStride * 2
            var out = [Double](repeating: 0, count: sets.count * width)
            guard !sets.isEmpty, slots > 0 else { return out }
            let n = matrix.rows
            out.withUnsafeMutableBufferPointer { hist in
                matrix.bins.withUnsafeBufferPointer { bins in
                    g.withUnsafeBufferPointer { gp in
                        h.withUnsafeBufferPointer { hp in
                            let tasks = sets.count * slots
                            DispatchQueue.concurrentPerform(iterations: tasks) { task in
                                let set = task / slots, slot = task % slots
                                let column = features[slot] * n
                                let base = set * width + slot * Self.binStride * 2
                                for row in sets[set] {
                                    let r = Int(row)
                                    let b = Int(bins[column + r]) * 2
                                    hist[base + b] += Double(gp[r])
                                    hist[base + b + 1] += Double(hp[r])
                                }
                            }
                        }
                    }
                }
            }
            return out
        }
    }

    /// The best split of every node, evaluated in parallel over (node, feature) and reduced per
    /// node in feature order.
    private func evaluate(_ nodes: [Node], histograms: [Double], gain: (Stats) -> Float) -> [Split] {
        let slots = features.count
        let width = slots * Self.binStride * 2
        var candidates = [Split](repeating: Split(), count: nodes.count * slots)
        let lambda = params.lambda, mcw = params.minChildWeight
        candidates.withUnsafeMutableBufferPointer { out in
            histograms.withUnsafeBufferPointer { hist in
                DispatchQueue.concurrentPerform(iterations: nodes.count * slots) { task in
                    let k = task / slots, slot = task % slots
                    let node = nodes[k]
                    if node.depth >= params.maxDepth { return }
                    let parentGain = gain(node.stats)
                    let base = node.histogram * width + slot * Self.binStride * 2
                    let candidatesHere = matrix.cuts[features[slot]].count
                    var best = Split()
                    var gl = 0.0, hl = 0.0
                    for b in 0..<candidatesHere {
                        gl += hist[base + 2 * b]
                        hl += hist[base + 2 * b + 1]
                        let gr = node.stats.g - gl, hr = node.stats.h - hl
                        if hl < mcw || hr < mcw { continue }
                        let gainLeft: Float = hl > 0 ? Float(gl * gl / (hl + lambda)) : 0
                        let gainRight: Float = hr > 0 ? Float(gr * gr / (hr + lambda)) : 0
                        let loss = (gainLeft + gainRight) - parentGain
                        if !loss.isFinite { continue }
                        if loss > best.loss {
                            best = Split(loss: loss, slot: slot, bin: b, left: Stats(g: gl, h: hl), right: Stats(g: gr, h: hr))
                        }
                    }
                    out[task] = best
                }
            }
        }
        return (0..<nodes.count).map { k in
            var best = Split()
            for slot in 0..<slots {
                let c = candidates[k * slots + slot]
                if c.slot >= 0 && c.loss > best.loss { best = c }
            }
            return best
        }
    }
}
