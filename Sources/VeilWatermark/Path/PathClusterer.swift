//
//  PathClusterer.swift
//  VeilWatermark
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Cluster path signatures by similarity, grouping paths that share similar hint sequences
//        and fragility profiles. The cluster centroid (representative path) becomes the region
//        signature. This approach is robust to resizing because path topology is preserved even
//        when absolute positions shift.
//  PIN:  Distance metric combines Hamming distance of hint bits with fragility profile similarity.
//        Clustering uses k-means-like iteration with path-based centroids. Region signatures are
//        the concatenated centroid hint sequences, maintaining the WatermarkSignature format.
//

import Foundation

public struct PathCluster: Sendable, Equatable {
    /// The cluster's representative path (centroid).
    public var centroid: PathSignature
    /// All paths assigned to this cluster.
    public var members: [PathSignature]
    /// The average distance of members from the centroid.
    public var averageDistance: Double
    /// The region this cluster represents (bounding box of member pixels).
    public var regionBounds: (minRow: Int, maxRow: Int, minCol: Int, maxCol: Int)
    
    public init(centroid: PathSignature, members: [PathSignature], averageDistance: Double, regionBounds: (Int, Int, Int, Int)) {
        self.centroid = centroid
        self.members = members
        self.averageDistance = averageDistance
        self.regionBounds = regionBounds
    }
    
    public static func == (lhs: PathCluster, rhs: PathCluster) -> Bool {
        lhs.averageDistance == rhs.averageDistance &&
        lhs.regionBounds == rhs.regionBounds &&
        lhs.centroid.anchor == rhs.centroid.anchor &&
        lhs.members.count == rhs.members.count
    }
}

public struct ClusteredSignature: Sendable, Equatable {
    /// The clusters grouped by region.
    public var clusters: [PathCluster]
    /// The concatenated centroid hint sequences forming the final signature.
    public var signatureBits: [UInt8]
    /// The masks for each bit in the signature.
    public var signatureMasks: [UInt8]
    /// The anchors that seeded these clusters.
    public var anchors: [PathAnchor]
    
    public init(clusters: [PathCluster], signatureBits: [UInt8], signatureMasks: [UInt8], anchors: [PathAnchor]) {
        self.clusters = clusters
        self.signatureBits = signatureBits
        self.signatureMasks = signatureMasks
        self.anchors = anchors
    }
}

public enum PathClusterer {
    
    /// Cluster a set of path signatures by similarity, returning region-based clusters.
    /// - Parameters:
    ///   - paths: The path signatures to cluster (from PathTracer.trace).
    ///   - k: The target number of clusters.
    ///   - distanceThreshold: Maximum distance for paths to be considered similar.
    /// - Returns: A ClusteredSignature with region clusters and their centroid-based signature.
    public static func cluster(paths: [PathSignature], k: Int, distanceThreshold: Double = 0.3) -> ClusteredSignature {
        guard !paths.isEmpty else {
            return ClusteredSignature(clusters: [], signatureBits: [], signatureMasks: [], anchors: [])
        }
        
        // Initialize clusters using k-means-like approach
        var clusters: [[Int]] = Array(repeating: [], count: k)
        var centroids: [PathSignature] = selectInitialCentroids(paths, k: k)
        
        // Iterate until convergence
        let maxIterations = 10
        for _ in 0..<maxIterations {
            // Assign each path to its nearest centroid
            var newClusters: [[Int]] = Array(repeating: [], count: k)
            for (i, path) in paths.enumerated() {
                let nearest = nearestCentroid(path, centroids: centroids)
                newClusters[nearest].append(i)
            }
            
            // Check for convergence
            if clusters == newClusters { break }
            clusters = newClusters
            
            // Recompute centroids
            centroids = computeCentroids(paths, clusters: clusters)
        }
        
        // Build PathCluster objects with region bounds and average distances
        let pathClusters = buildPathClusters(paths, clusters: clusters, centroids: centroids)
        
        // Extract signature bits and masks from cluster centroids
        let (signatureBits, signatureMasks) = extractSignature(from: pathClusters)
        
        return ClusteredSignature(
            clusters: pathClusters,
            signatureBits: signatureBits,
            signatureMasks: signatureMasks,
            anchors: pathClusters.map { $0.centroid.anchor }
        )
    }
    
    /// Compute the distance between two paths based on hint similarity and fragility profile.
    private static func pathDistance(_ a: PathSignature, _ b: PathSignature) -> Double {
        let hintsA = a.hints
        let hintsB = b.hints
        let count = min(hintsA.count, hintsB.count)
        
        guard count > 0 else { return 1.0 }
        
        var totalDistance: Double = 0
        for i in 0..<count {
            let hA = hintsA[i]
            let hB = hintsB[i]
            
            // Hamming distance of hint bits (weighted by mask)
            let commonMask = hA.mask & hB.mask
            if commonMask > 0 {
                let differingBits = ((hA.bits ^ hB.bits) & commonMask).nonzeroBitCount
                let bitDistance = Double(differingBits) / Double(commonMask.nonzeroBitCount)
                totalDistance += bitDistance
            }
            
            // Fragility profile similarity (direction-aware)
            let dirDiff: Double
            switch (hA.direction, hB.direction) {
                case (.towardAnchor(let r1, let c1), .towardAnchor(let r2, let c2)):
                    dirDiff = directionDistance(r1, c1, r2, c2)
                case (.retracing(let r1, let c1), .retracing(let r2, let c2)):
                    dirDiff = directionDistance(r1, c1, r2, c2)
                default:
                    dirDiff = 0.5
            }
            
            totalDistance += dirDiff * 0.3  // Weight direction less than bits
        }
        
        return totalDistance / Double(count)
    }
    
    /// Find the index of the centroid nearest to the given path.
    private static func nearestCentroid(_ path: PathSignature, centroids: [PathSignature]) -> Int {
        guard !centroids.isEmpty else { return 0 }
        
        var bestIndex = 0
        var bestDistance = pathDistance(path, centroids[0])
        
        for (i, centroid) in centroids.enumerated() {
            let dist = pathDistance(path, centroid)
            if dist < bestDistance {
                bestDistance = dist
                bestIndex = i
            }
        }
        
        return bestIndex
    }
    
    /// Compute distance between two direction vectors.
    private static func directionDistance(_ r1: Int, _ c1: Int, _ r2: Int, _ c2: Int) -> Double {
        let dr1 = Double(r2 - r1)
        let dc1 = Double(c2 - c1)
        let dr2 = Double(r2 - r1)  // Same target for retracing
        let dc2 = Double(c2 - c1)
        
        let mag1 = sqrt(dr1 * dr1 + dc1 * dc1)
        let mag2 = sqrt(dr2 * dr2 + dc2 * dc2)
        
        guard mag1 > 0 && mag2 > 0 else { return 0.5 }
        
        // Cosine similarity of direction vectors
        let dot = dr1 * dr2 + dc1 * dc2
        let cosSim = dot / (mag1 * mag2)
        return 1.0 - cosSim  // Distance = 1 - similarity
    }
    
    /// Select initial centroids using k-means++ style initialization.
    private static func selectInitialCentroids(_ paths: [PathSignature], k: Int) -> [PathSignature] {
        guard !paths.isEmpty else { return [] }
        
        var centroids: [PathSignature] = []
        var chosenIndices: Set<Int> = []
        
        // Pick first centroid randomly
        let firstIndex = Int.random(in: 0..<paths.count)
        centroids.append(paths[firstIndex])
        chosenIndices.insert(firstIndex)
        
        // Pick remaining centroids with probability proportional to distance
        for _ in 1..<k {
            var distances: [Double] = []
            for (i, path) in paths.enumerated() where !chosenIndices.contains(i) {
                let minDist = centroids.map { pathDistance(path, $0) }.min() ?? 1.0
                distances.append(minDist)
            }
            
            let totalDist = distances.reduce(0, +)
            guard totalDist > 0 else {
                // Fallback: pick unchosen at random
                let remaining = paths.indices.filter { !chosenIndices.contains($0) }
                if !remaining.isEmpty {
                    let idx = remaining.randomElement()!
                    centroids.append(paths[idx])
                    chosenIndices.insert(idx)
                }
                continue
            }
            
            var cumulative: Double = 0
            let target = Double.random(in: 0..<totalDist)
            for (i, d) in distances.enumerated() {
                cumulative += d
                if cumulative >= target {
                    let actualIndex = paths.indices.filter { !chosenIndices.contains($0) }[i]
                    centroids.append(paths[actualIndex])
                    chosenIndices.insert(actualIndex)
                    break
                }
            }
        }
        
        return centroids
    }
    
    /// Compute new centroids as the path minimizing total distance to cluster members.
    private static func computeCentroids(_ paths: [PathSignature], clusters: [[Int]]) -> [PathSignature] {
        clusters.map { memberIndices in
            guard !memberIndices.isEmpty else {
                return PathSignature(anchor: PathAnchor(row: 0, col: 0, fragility: 0), hints: [], isRetracing: false)
            }
            
            // Find the path that minimizes total distance to all members
            var bestPath = paths[memberIndices[0]]
            var bestTotalDist = Double.infinity
            
            for memberIdx in memberIndices {
                let candidate = paths[memberIdx]
                let totalDist = memberIndices.reduce(0.0) { $0 + pathDistance(paths[$1], candidate) }
                if totalDist < bestTotalDist {
                    bestTotalDist = totalDist
                    bestPath = candidate
                }
            }
            
            return bestPath
        }
    }
    
    /// Build PathCluster objects with region bounds and average distances.
    private static func buildPathClusters(_ paths: [PathSignature], clusters: [[Int]], centroids: [PathSignature]) -> [PathCluster] {
        zip(clusters, centroids).map { (memberIndices, centroid) in
            let memberPaths = memberIndices.map { paths[$0] }
            
            // Compute average distance from centroid
            let avgDist = memberPaths.reduce(0.0) { $0 + pathDistance($1, centroid) } / Double(memberPaths.count)
            
            // Compute region bounds from all hints in cluster members
            var minRow = Int.max, maxRow = Int.min, minCol = Int.max, maxCol = Int.min
            for path in memberPaths {
                for hint in path.hints {
                    minRow = min(minRow, hint.row)
                    maxRow = max(maxRow, hint.row)
                    minCol = min(minCol, hint.col)
                    maxCol = max(maxCol, hint.col)
                }
            }
            
            return PathCluster(
                centroid: centroid,
                members: memberPaths,
                averageDistance: avgDist,
                regionBounds: (minRow, maxRow, minCol, maxCol)
            )
        }
    }
    
    /// Extract signature bits and masks from cluster centroids.
    private static func extractSignature(from clusters: [PathCluster]) -> ([UInt8], [UInt8]) {
        var bits: [UInt8] = []
        var masks: [UInt8] = []
        
        for cluster in clusters {
            // Use the centroid's hints as the representative signature
            for hint in cluster.centroid.hints {
                bits.append(hint.bits)
                masks.append(hint.mask)
            }
        }
        
        return (bits, masks)
    }
}

// MARK: - Extension for UInt8 nonzero bit count

extension UInt8 {
    var nonzeroBitCount: Int {
        var count = 0
        var value = self
        while value > 0 {
            count += Int(value & 1)
            value >>= 1
        }
        return count
    }
}
