//
//  WatermarkPath.swift
//  VeilGardeCLI
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: `veilgarde watermark sign-path`, `match-path` and `cluster`: the path-based watermarking
//        approach that traces paths from anchor pixels, clusters them by similarity, and derives
//        signatures from cluster centroids. More robust to resizing and compression than the
//        sectioned tile-code approach.
//  PIN:  Uses PathTracer to compute hints along paths, PathClusterer to group similar paths, and
//        produces WatermarkSignature from cluster centroids. Anchors are chosen from high-fragility
//        regions to ensure they survive geometric transformations.
//

import ArgumentParser
import CoreGraphics
import Foundation
import VeilGarde
import VeilWatermark

extension WatermarkCommand {
    
    struct SignPath: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sign-path", abstract: "Sign an image using the path-based approach: trace paths from anchors, cluster, derive signature.",
            discussion: "More robust to resizing and re-encoding than sectioned tile codes. Anchors are chosen from high-fragility regions.")
        
        @Argument(help: "The image to sign.") var image: String
        @Option(help: "Number of anchor pixels/clusters to choose.") var anchors: Int = 8
        @Option(help: "Target number of path clusters.") var k: Int = 4
        @Flag(help: "JSON instead of vw1 text.") var json = false
        
        func run() throws {
            guarded {
                let cg = try loadImage(image)
                let sig = try Watermark.signPath(cg, anchorCount: anchors, clusterK: k)
                
                if json {
                    try emitJSON(try JSONCoding.prettyEncoder().encode(sig), to: "-")
                } else {
                    print(sig.compact)
                }
                
                note("\(sig.rows)×\(sig.cols) tiles, \(sig.codes.count) sections, \(sig.measuredBits) bits, cid \(sig.cid.prefix(16))")
                note("anchors: \(anchors), clusters: \(k)")
            }
        }
    }
    
    struct MatchPath: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "match-path", abstract: "Find where an image sits on a path-based signature, with phase search.",
            discussion: "Matches against the clustered path signature. Phases allow sub-tile alignment.")
        
        @Argument(help: "The image (a crop, re-encode or resized version of a signed one).") var image: String
        @Argument(help: "The path-based signature: vw1 text, or a file holding vw1 text or JSON.") var signature: String
        @Option(help: "Grid phases in pixels, comma-separated.") var phases: String = "0,8,16,24"
        @Flag(help: "JSON instead of text.") var json = false
        
        func run() throws {
            guarded {
                let p = phases.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                let sig = try WatermarkCommand.signature(signature)
                let r = try Watermark.match(try loadImage(image), against: sig, options: MatchOptions(phases: p))
                
                if json {
                    try emitJSON(try JSONCoding.prettyEncoder().encode(r), to: "-")
                } else {
                    print(String(format: "%@: score %.4f over %d bits (z %.1f); offset (%d, %d) tiles at phase (%d, %d) px, the image's origin at (%d, %d) on the signed image",
                                 r.matched ? "match" : "no match", r.score, r.bitsCompared, r.zScore, r.offsetX, r.offsetY, r.phaseX, r.phaseY, r.pixelX, r.pixelY))
                }
            }
        }
    }
    
    struct Cluster: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cluster", abstract: "Cluster paths from an image's fragility grid and report the cluster structure.",
            discussion: "Outputs cluster centroids, member counts, average distances and region bounds. Useful for debugging and analysis.")
        
        @Argument(help: "The image to analyze.") var image: String
        @Option(help: "Number of anchors to choose.") var anchors: Int = 8
        @Option(help: "Target number of clusters.") var k: Int = 4
        @Flag(inversion: .prefixedNo, help: "Include retracing paths in clustering.") var retrace = true
        @Flag(help: "JSON output.") var json = false
        
        func run() throws {
            guarded {
                let cg = try loadImage(image)
                let plane = try NativePlane(cg)
                let fragilityGrid = plane.fragility()
                
                let anchors = PathTracer.chooseAnchors(from: fragilityGrid, count: self.anchors, minFragility: 0.5)
                let tracerResult = PathTracer.trace(grid: fragilityGrid, anchors: anchors, includeRetracing: retrace)
                
                let allPaths = tracerResult.forwardPaths + (retrace ? tracerResult.retracingPaths : [])
                let clustered = PathClusterer.cluster(paths: allPaths, k: self.k)
                
                if json {
                    let report: [String: Any] = [
                        "anchors": anchors.map { ["row": $0.row, "col": $0.col, "fragility": $0.fragility] },
                        "clusters": clustered.clusters.map { cluster in
                            [
                                "centroidAnchor": ["row": cluster.centroid.anchor.row, "col": cluster.centroid.anchor.col],
                                "memberCount": cluster.members.count,
                                "averageDistance": cluster.averageDistance.isFinite ? cluster.averageDistance : 0.0,
                                "regionBounds": [
                                    "minRow": cluster.regionBounds.minRow,
                                    "maxRow": cluster.regionBounds.maxRow,
                                    "minCol": cluster.regionBounds.minCol,
                                    "maxCol": cluster.regionBounds.maxCol
                                ]
                            ]
                        },
                        "signatureBitsCount": clustered.signatureBits.count,
                        "signatureMasksCount": clustered.signatureMasks.count
                    ]
                    
                    let data = try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted)
                    print(String(data: data, encoding: .utf8)!)
                } else {
                    print("Anchors (\(anchors.count)):")
                    for a in anchors {
                        print(String(format: "  (%d, %d) fragility %.3f", a.row, a.col, a.fragility))
                    }
                    
                    print("\nClusters (\(clustered.clusters.count)):")
                    for (i, cluster) in clustered.clusters.enumerated() {
                        print(String(format: "  Cluster %d: centroid at (%d, %d), %d members, avg dist %.3f, region [%d,%d]×[%d,%d]",
                                     i,
                                     cluster.centroid.anchor.row, cluster.centroid.anchor.col,
                                     cluster.members.count, cluster.averageDistance,
                                     cluster.regionBounds.minRow, cluster.regionBounds.maxRow,
                                     cluster.regionBounds.minCol, cluster.regionBounds.maxCol))
                    }
                    
                    print("\nSignature: \(clustered.signatureBits.count) bits, \(clustered.signatureMasks.count) masks")
                }
            }
        }
    }
    
    struct Compare: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "compare", abstract: "Compare sectioned tile-code and path-based signatures for the same image.",
            discussion: "Runs both signing approaches and shows measured bits, grid dimensions, CID, and compact form side-by-side.")
        
        @Argument(help: "The image to sign with both approaches.") var image: String
        @Option(help: "Number of anchors for path-based signing.") var anchors: Int = 8
        @Option(help: "Target number of clusters for path-based signing.") var k: Int = 4
        
        func run() throws {
            guarded {
                let cg = try loadImage(image)
                
                // Sectioned tile-code signature
                let sectionedSig = try Watermark.sign(cg)
                
                // Path-based signature
                let pathSig = try Watermark.signPath(cg, anchorCount: anchors, clusterK: k)
                
                print("Sectioned (original):")
                print("  Grid: \(sectionedSig.rows)×\(sectionedSig.cols) tiles")
                print("  Sections: \(sectionedSig.codes.count)")
                print("  Measured bits: \(sectionedSig.measuredBits)")
                print("  CID: \(sectionedSig.cid.prefix(16))")
                print("  Compact SHA256: \(ContentHash.sha256Hex(sectionedSig.compact).prefix(16))")
                
                print("\nPath-based:")
                print("  Grid: \(pathSig.rows)×\(pathSig.cols) tiles")
                print("  Sections: \(pathSig.codes.count)")
                print("  Measured bits: \(pathSig.measuredBits)")
                print("  CID: \(pathSig.cid.prefix(16))")
                print("  Compact SHA256: \(ContentHash.sha256Hex(pathSig.compact).prefix(16))")
                
                print("\nComparison:")
                let gridMatch = sectionedSig.rows == pathSig.rows && sectionedSig.cols == pathSig.cols
                let bitsMatch = sectionedSig.measuredBits == pathSig.measuredBits
                let cidMatch = sectionedSig.cid == pathSig.cid
                let compactMatch = sectionedSig.compact == pathSig.compact
                
                print("  Grid dimensions match: \(gridMatch ? "yes" : "no")")
                print("  Measured bits match: \(bitsMatch ? "yes" : "no")")
                print("  CID match: \(cidMatch ? "yes" : "no")")
                print("  Compact form match: \(compactMatch ? "yes" : "no")")
                
                if compactMatch {
                    print("\n✓ Path-based signature produces identical compact form to sectioned tile-code.")
                } else {
                    print("\n✗ Signatures differ. Compact forms:")
                    print("  Sectioned: \(sectionedSig.compact.prefix(80))...")
                    print("  Path-based: \(pathSig.compact.prefix(80))...")
                }
            }
        }
    }
    
    struct ResizingTest: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "resizing-test", abstract: "Test signature robustness under image resizing.",
            discussion: "Signs an image at multiple scales and compares signatures to measure how well they survive resizing.")
        
        @Argument(help: "The original image to test.") var image: String
        @Option(help: "Resize scales as percentages, comma-separated (e.g. 50,75,150).") var scales: String = "50,75,150,200"
        @Option(help: "Number of anchors for path-based signing.") var anchors: Int = 8
        @Option(help: "Target number of clusters for path-based signing.") var k: Int = 4
        
        func run() throws {
            guarded {
                let originalCG = try loadImage(image)
                let originalWidth = originalCG.width
                let originalHeight = originalCG.height
                
                // Sign the original with both approaches
                let originalSectioned = try Watermark.sign(originalCG)
                let originalPath = try Watermark.signPath(originalCG, anchorCount: anchors, clusterK: k)
                
                print("Original image: \(originalWidth)×\(originalHeight)")
                print("  Sectioned signature: cid \(String(originalSectioned.cid.prefix(16))), \(originalSectioned.measuredBits) bits")
                print("  Path-based signature: cid \(String(originalPath.cid.prefix(16))), \(originalPath.measuredBits) bits")
                print()
                
                func pad(_ text: String, _ width: Int) -> String { text.count >= width ? text : text + String(repeating: " ", count: width - text.count) }
                let scaleValues = scales.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                
                print("Resizing test (match = the resized image against the original's signature, default thresholds):")
                let columns = [("Scale", 7), ("Size", 12), ("Sectioned", 28), ("Path-based", 28)]
                print(columns.map { pad($0.0, $0.1) }.joined(separator: " "))
                print(String(repeating: "-", count: columns.map { $0.1 + 1 }.reduce(0, +) - 1))

                for scale in scaleValues where scale > 0 {
                    // ImageCodec.resized: 8-bit device RGB, bytesPerRow chosen by CoreGraphics, high interpolation.
                    guard let resizedCG = ImageCodec.resized(originalCG, by: Double(scale) / 100.0) else {
                        note("scale \(scale)%: resize failed")
                        continue
                    }

                    func outcome(_ sig: WatermarkSignature) -> String {
                        guard let r = try? Watermark.match(resizedCG, against: sig, options: .default) else { return "error" }
                        return String(format: "%@ %.3f over %d bits", r.matched ? "match" : "no match", r.score, r.bitsCompared)
                    }

                    print([pad("\(scale)%", 7), pad("\(resizedCG.width)×\(resizedCG.height)", 12),
                           pad(outcome(originalSectioned), 28), pad(outcome(originalPath), 28)].joined(separator: " "))
                }

                print()
                print("Note: the tile grid is 32 px in absolute pixels, so a resize moves every tile boundary; a match at a scale other than 100% would be the exception.")
            }
        }
    }
}
