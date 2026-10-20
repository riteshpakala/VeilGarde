//
//  GBDTModel.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A gradient-boosted tree ensemble (binary logistic) as a value: decoded from and encoded to
//        the XGBoost ≥ 2.0 JSON every VeilGarde booster ships as (the warp tile model, the fusion head,
//        its frozen reference), and evaluated on feature rows. It is what the trainer writes and
//        what a warm start continues.
//  PIN:  Byte-identical round trip: encoding a decoded model writes the file's exact bytes,
//        because every inherited tree keeps its JSON text (`raw`) and the rest follows XGBoost
//        3.2's compact, sorted layout. Numbers are decoded with JSONDecoder into Float, as
//        Frigate's XGBoostTreeModel decodes them, and evaluated the same way: margin =
//        logit(base_score) in Double then cast, leaves summed in Float in tree order, a sample
//        goes left when value < condition, a missing column reads 0, sigmoid in Float. So a
//        GBDTModel and Frigate's evaluator agree bit for bit on the same file.
//

import Foundation

public struct GBDTModel: TileScorer, Sendable, Equatable {
    /// One tree, as XGBoost stores it: parallel arrays indexed by node, −1 children for a leaf.
    public struct Tree: Sendable, Equatable {
        public var id: Int
        public var leftChildren: [Int32]
        public var rightChildren: [Int32]
        public var parents: [Int32]
        public var splitIndices: [Int32]
        /// The threshold at an internal node; the leaf value at a leaf.
        public var splitConditions: [Float]
        /// The node weight −G/(H + λ) at an internal node; the leaf value (η-scaled) at a leaf.
        public var baseWeights: [Float]
        public var defaultLeft: [Int]
        public var splitType: [Int]
        public var lossChanges: [Float]
        public var sumHessian: [Float]
        public var numFeature: Int
        /// The tree's JSON text exactly as decoded; encoding splices it back verbatim.
        public var raw: String?

        public static let rootParent: Int32 = 2_147_483_647

        public init(id: Int, leftChildren: [Int32], rightChildren: [Int32], parents: [Int32], splitIndices: [Int32],
                    splitConditions: [Float], baseWeights: [Float], defaultLeft: [Int], splitType: [Int],
                    lossChanges: [Float], sumHessian: [Float], numFeature: Int, raw: String? = nil) {
            self.id = id
            self.leftChildren = leftChildren
            self.rightChildren = rightChildren
            self.parents = parents
            self.splitIndices = splitIndices
            self.splitConditions = splitConditions
            self.baseWeights = baseWeights
            self.defaultLeft = defaultLeft
            self.splitType = splitType
            self.lossChanges = lossChanges
            self.sumHessian = sumHessian
            self.numFeature = numFeature
            self.raw = raw
        }

        public var nodeCount: Int { leftChildren.count }
        public var leafCount: Int { leftChildren.filter { $0 == -1 }.count }

        /// The depth of the deepest leaf (a lone root is depth 0).
        public var depth: Int {
            var deepest = 0
            var stack: [(Int, Int)] = [(0, 0)]
            while let (node, d) = stack.popLast() {
                if leftChildren[node] == -1 { deepest = max(deepest, d); continue }
                stack.append((Int(leftChildren[node]), d + 1))
                stack.append((Int(rightChildren[node]), d + 1))
            }
            return deepest
        }

        /// Walks the tree for one row and returns the leaf value.
        @inline(__always)
        public func leafValue(for features: [Float]) -> Float {
            var node = 0
            while leftChildren[node] != -1 {
                let fi = Int(splitIndices[node])
                let fv = fi < features.count ? features[fi] : 0
                node = fv < splitConditions[node] ? Int(leftChildren[node]) : Int(rightChildren[node])
            }
            return baseWeights[node]
        }
    }

    public var trees: [Tree]
    /// learner_model_param.base_score exactly as stored (XGBoost writes "[5.11784E-1]").
    public var baseScore: String
    public var featureCount: Int
    public var scalePosWeight: String
    public var version: [Int]
    public var attributes: [String: String]
    public var featureNames: [String]
    public var featureTypes: [String]
    /// learner_model_param's other entries, kept so they encode back unchanged.
    public var learnerParameters: [String: String]
    /// gradient_booster.model.cats as stored (empty for every shipped booster).
    public var categoriesRaw: String

    public static let emptyCategories = #"{"enc":[],"feature_segments":[],"sorted_idx":[]}"#

    /// A fresh ensemble, as the trainer builds one.
    public init(trees: [Tree], baseScoreProbability: Float, featureCount: Int, scalePosWeight: Float = 1,
                attributes: [String: String] = [:], featureNames: [String] = [], featureTypes: [String] = []) {
        self.trees = trees
        self.baseScore = "[\(Self.number(baseScoreProbability))]"
        self.featureCount = featureCount
        self.scalePosWeight = Self.number(scalePosWeight)
        self.version = [3, 2, 0]
        self.attributes = attributes
        self.featureNames = featureNames
        self.featureTypes = featureTypes
        self.learnerParameters = ["boost_from_average": "1", "num_class": "0", "num_target": "1"]
        self.categoriesRaw = Self.emptyCategories
    }

    // MARK: Evaluation

    /// base_score as a probability, parsed the way Frigate's evaluator parses it.
    public var baseScoreProbability: Float {
        var s = baseScore.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("["), s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        return Float(s) ?? 0.5
    }

    /// logit(base_score), computed in Double from the clamped probability, then cast.
    public var baseMargin: Float {
        let clamped = max(1e-7, min(1 - 1e-7, Double(baseScoreProbability)))
        return Float(log(clamped / (1.0 - clamped)))
    }

    /// The raw margin for one row: logit(base_score) plus every leaf, summed in tree order.
    public func margin(_ features: [Float]) -> Float {
        var m = baseMargin
        for tree in trees { m += tree.leafValue(for: features) }
        return m
    }

    /// P(class 1) for one row.
    public func predict(_ features: [Float]) -> Float {
        1.0 / (1.0 + Foundation.exp(-margin(features)))
    }

    public func scoreBatch(_ rows: [[Float]]) -> [Float] { rows.map(predict) }

    // MARK: Decoding

    public static func decode(xgboostJSON data: Data) throws -> GBDTModel {
        let file: FileJSON
        do {
            file = try JSONDecoder().decode(FileJSON.self, from: data)
        } catch {
            throw VeilGardeFailure.data("not an XGBoost JSON model: \(error)")
        }
        let learner = file.learner
        guard learner.objective.name == "binary:logistic" else {
            throw VeilGardeFailure.data("objective \(learner.objective.name) is not binary:logistic")
        }
        let text = [UInt8](data)
        let raws = try Self.treeRanges(in: text)
        guard raws.count == learner.gradient_booster.model.trees.count else {
            throw VeilGardeFailure.data("found \(raws.count) tree objects for \(learner.gradient_booster.model.trees.count) trees")
        }
        let categoriesRaw = Self.valueRange(ofKey: "cats", in: text).map { String(decoding: text[$0], as: UTF8.self) } ?? Self.emptyCategories
        var parameters = learner.learner_model_param
        let baseScore = parameters.removeValue(forKey: "base_score") ?? "[5E-1]"
        let numFeature = Int(parameters.removeValue(forKey: "num_feature") ?? "") ?? 0
        let trees = zip(learner.gradient_booster.model.trees, raws).map { tree, range in
            Tree(id: tree.id, leftChildren: tree.left_children, rightChildren: tree.right_children, parents: tree.parents,
                 splitIndices: tree.split_indices, splitConditions: tree.split_conditions, baseWeights: tree.base_weights,
                 defaultLeft: tree.default_left, splitType: tree.split_type, lossChanges: tree.loss_changes,
                 sumHessian: tree.sum_hessian, numFeature: Int(tree.tree_param["num_feature"] ?? "") ?? numFeature,
                 raw: String(decoding: text[range], as: UTF8.self))
        }
        var model = GBDTModel(trees: trees, baseScoreProbability: 0.5, featureCount: numFeature)
        model.baseScore = baseScore
        model.scalePosWeight = learner.objective.reg_loss_param?["scale_pos_weight"] ?? "1"
        model.version = file.version
        model.attributes = learner.attributes
        model.featureNames = learner.feature_names
        model.featureTypes = learner.feature_types
        model.learnerParameters = parameters
        model.categoriesRaw = categoriesRaw
        return model
    }

    public static func load(_ url: URL) throws -> GBDTModel { try decode(xgboostJSON: Data(contentsOf: url)) }

    // MARK: Encoding

    /// XGBoost 3.2's compact, sorted JSON. Trees decoded from a file are spliced back verbatim.
    public func encodeXGBoostJSON() -> Data {
        var out = "{\"learner\":{"
        out += "\"attributes\":" + Self.object(attributes) + ","
        out += "\"feature_names\":" + Self.strings(featureNames) + ","
        out += "\"feature_types\":" + Self.strings(featureTypes) + ","
        out += "\"gradient_booster\":{\"model\":{"
        out += "\"cats\":" + categoriesRaw + ","
        out += "\"gbtree_model_param\":{\"num_parallel_tree\":\"1\",\"num_trees\":\"\(trees.count)\"},"
        out += "\"iteration_indptr\":[" + (0...trees.count).map(String.init).joined(separator: ",") + "],"
        out += "\"tree_info\":[" + Array(repeating: "0", count: trees.count).joined(separator: ",") + "],"
        out += "\"trees\":[" + trees.map(Self.encode(tree:)).joined(separator: ",") + "]"
        out += "},\"name\":\"gbtree\"},"
        var parameters = learnerParameters
        parameters["base_score"] = baseScore
        parameters["num_feature"] = String(featureCount)
        out += "\"learner_model_param\":" + Self.object(parameters) + ","
        out += "\"objective\":{\"name\":\"binary:logistic\",\"reg_loss_param\":{\"scale_pos_weight\":\"\(scalePosWeight)\"}}"
        out += "},\"version\":[" + version.map(String.init).joined(separator: ",") + "]}"
        return Data(out.utf8)
    }

    static func encode(tree: Tree) -> String {
        if let raw = tree.raw { return raw }
        func floats(_ v: [Float]) -> String { "[" + v.map(number).joined(separator: ",") + "]" }
        func ints<T: BinaryInteger>(_ v: [T]) -> String { "[" + v.map { String($0) }.joined(separator: ",") + "]" }
        var out = "{"
        out += "\"base_weights\":" + floats(tree.baseWeights) + ","
        out += "\"categories\":[],\"categories_nodes\":[],\"categories_segments\":[],\"categories_sizes\":[],"
        out += "\"default_left\":" + ints(tree.defaultLeft) + ","
        out += "\"id\":\(tree.id),"
        out += "\"left_children\":" + ints(tree.leftChildren) + ","
        out += "\"loss_changes\":" + floats(tree.lossChanges) + ","
        out += "\"parents\":" + ints(tree.parents) + ","
        out += "\"right_children\":" + ints(tree.rightChildren) + ","
        out += "\"split_conditions\":" + floats(tree.splitConditions) + ","
        out += "\"split_indices\":" + ints(tree.splitIndices) + ","
        out += "\"split_type\":" + ints(tree.splitType) + ","
        out += "\"sum_hessian\":" + floats(tree.sumHessian) + ","
        out += "\"tree_param\":{\"num_deleted\":\"0\",\"num_feature\":\"\(tree.numFeature)\",\"num_nodes\":\"\(tree.nodeCount)\",\"size_leaf_vector\":\"1\"}"
        return out + "}"
    }

    /// A Float's shortest round-trip spelling, JSON-safe.
    static func number(_ value: Float) -> String {
        guard value.isFinite else { return "0" }
        let text = value.description
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func strings(_ values: [String]) -> String {
        "[" + values.map(quote).joined(separator: ",") + "]"
    }

    static func object(_ values: [String: String]) -> String {
        "{" + values.keys.sorted().map { "\(quote($0)):\(quote(values[$0]!))" }.joined(separator: ",") + "}"
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }

    // MARK: Raw scanning

    /// The byte range of every object in the "trees" array.
    static func treeRanges(in text: [UInt8]) throws -> [Range<Int>] {
        guard let start = find(Array(#""trees":["#.utf8), in: text) else { return [] }
        var i = start + 9
        var ranges: [Range<Int>] = []
        while i < text.count {
            while i < text.count, text[i] == 0x20 || text[i] == 0x0A || text[i] == 0x0D || text[i] == 0x09 || text[i] == 0x2C { i += 1 }
            guard i < text.count else { break }
            if text[i] == 0x5D { return ranges }      // ]
            guard text[i] == 0x7B else { throw VeilGardeFailure.data("unexpected byte in the trees array at \(i)") }
            let end = try matching(from: i, in: text)
            ranges.append(i..<(end + 1))
            i = end + 1
        }
        throw VeilGardeFailure.data("the trees array is not closed")
    }

    /// The byte range of the value of the first `"key":` in `text` (an object or array).
    static func valueRange(ofKey key: String, in text: [UInt8]) -> Range<Int>? {
        guard let at = find(Array("\"\(key)\":".utf8), in: text) else { return nil }
        let start = at + key.utf8.count + 3
        guard start < text.count, text[start] == 0x7B || text[start] == 0x5B, let end = try? matching(from: start, in: text) else { return nil }
        return start..<(end + 1)
    }

    /// The index of the bracket closing the one at `start`, skipping strings.
    static func matching(from start: Int, in text: [UInt8]) throws -> Int {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < text.count {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == 0x5C { escaped = true } else if c == 0x22 { inString = false }
            } else if c == 0x22 {
                inString = true
            } else if c == 0x7B || c == 0x5B {
                depth += 1
            } else if c == 0x7D || c == 0x5D {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        throw VeilGardeFailure.data("an unclosed bracket at byte \(start)")
    }

    static func find(_ needle: [UInt8], in text: [UInt8]) -> Int? {
        guard !needle.isEmpty, text.count >= needle.count else { return nil }
        let first = needle[0]
        var i = 0
        let last = text.count - needle.count
        while i <= last {
            if text[i] == first {
                var j = 1
                while j < needle.count, text[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: JSON mirror

    private struct FileJSON: Decodable {
        let learner: LearnerJSON
        let version: [Int]
    }

    private struct LearnerJSON: Decodable {
        let attributes: [String: String]
        let feature_names: [String]
        let feature_types: [String]
        let gradient_booster: BoosterJSON
        let learner_model_param: [String: String]
        let objective: ObjectiveJSON
    }

    private struct BoosterJSON: Decodable {
        let model: ModelJSON
        let name: String
    }

    private struct ModelJSON: Decodable {
        let trees: [TreeJSON]
    }

    private struct ObjectiveJSON: Decodable {
        let name: String
        let reg_loss_param: [String: String]?
    }

    private struct TreeJSON: Decodable {
        let id: Int
        let base_weights: [Float]
        let default_left: [Int]
        let left_children: [Int32]
        let loss_changes: [Float]
        let parents: [Int32]
        let right_children: [Int32]
        let split_conditions: [Float]
        let split_indices: [Int32]
        let split_type: [Int]
        let sum_hessian: [Float]
        let tree_param: [String: String]
    }
}
