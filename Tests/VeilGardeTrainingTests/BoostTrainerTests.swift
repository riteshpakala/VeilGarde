//
//  BoostTrainerTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The native trainer against xgboost 3.2. On integer features (so the bins are the values
//        themselves) it grows XGBoost's trees: the same splits, children and node order, leaves
//        and gains within float rounding, with weights, scale_pos_weight, γ, λ and
//        min_child_weight. On continuous data it lands within ±0.005 AUC and ±0.01 log loss of
//        xgboost's model, a warm start continues a model xgboost wrote without touching its
//        trees, and every model it writes reads back through Frigate's evaluator unchanged. A
//        column mask keeps the data's width and grows, node for node, a refit on only its columns.
//

import Foundation
import Frigate
import Testing
import VeilGardeCore
@testable import VeilGardeTraining

@Suite("GBDT trainer")
struct BoostTrainerTests {
    static func exactData() throws -> (fixture: [String: Any], data: BoostDataset, weighted: BoostDataset) {
        let fixture = try Fixture.json("boost_exact.json")
        let rows = fixture["X"] as! [[NSNumber]]
        let x = rows.flatMap { $0.map(\.floatValue) }
        let y = floats(fixture["y"]), w = floats(fixture["w"])
        return (fixture, BoostDataset(x: x, y: y, features: 4), BoostDataset(x: x, y: y, weight: w, features: 4))
    }

    @Test("integer features: xgboost's trees, node for node", arguments: ["plain", "weighted_spw", "gamma_mcw_lambda"])
    func exact(_ name: String) throws {
        let (fixture, plain, weighted) = try Self.exactData()
        let c = (fixture["cases"] as! [[String: Any]]).first { $0["name"] as! String == name }!
        let p = c["params"] as! [String: Any]
        var params = BoostParams(trees: c["rounds"] as! Int, maxDepth: p["max_depth"] as! Int, eta: double(p["eta"]))
        if let v = p["base_score"] { params.baseScore = double(v) }
        if let v = p["scale_pos_weight"] { params.scalePosWeight = double(v) }
        if let v = p["gamma"] { params.gamma = double(v) }
        if let v = p["min_child_weight"] { params.minChildWeight = double(v) }
        if let v = p["lambda"] { params.lambda = double(v) }
        let data = (c["weighted"] as! Bool) ? weighted : plain
        let result = BoostTrainer.train(data, params: params)
        let model = result.model

        let expectedBase = GBDTModel(trees: [], baseScoreProbability: 0.5, featureCount: 4)
        var stored = expectedBase; stored.baseScore = c["base_score"] as! String
        #expect(abs(model.baseScoreProbability - stored.baseScoreProbability) <= 1e-6, "\(name): base_score \(model.baseScore) vs \(stored.baseScore)")

        let trees = c["trees"] as! [[String: Any]]
        #expect(model.trees.count == trees.count)
        for (k, (mine, theirs)) in zip(model.trees, trees).enumerated() {
            #expect(mine.leftChildren.map(Int.init) == ints(theirs["left_children"]), "\(name) tree \(k): left")
            #expect(mine.rightChildren.map(Int.init) == ints(theirs["right_children"]), "\(name) tree \(k): right")
            #expect(mine.parents.map(Int.init) == ints(theirs["parents"]), "\(name) tree \(k): parents")
            #expect(mine.splitIndices.map(Int.init) == ints(theirs["split_indices"]), "\(name) tree \(k): split features")
            #expect(mine.defaultLeft == ints(theirs["default_left"]), "\(name) tree \(k): default_left")
            let conditions = floats(theirs["split_conditions"]), weights = floats(theirs["base_weights"])
            let losses = floats(theirs["loss_changes"]), hessians = floats(theirs["sum_hessian"])
            for i in 0..<min(mine.nodeCount, conditions.count) {
                #expect(abs(mine.splitConditions[i] - conditions[i]) <= 1e-5 * max(1, abs(conditions[i])), "\(name) tree \(k) node \(i): condition")
                #expect(abs(mine.baseWeights[i] - weights[i]) <= 1e-5 * max(1, abs(weights[i])), "\(name) tree \(k) node \(i): weight")
                #expect(abs(mine.lossChanges[i] - losses[i]) <= 1e-4 * max(1, abs(losses[i])), "\(name) tree \(k) node \(i): loss change")
                #expect(abs(mine.sumHessian[i] - hessians[i]) <= 1e-4 * max(1, abs(hessians[i])), "\(name) tree \(k) node \(i): hessian")
            }
        }
        let margins = floats(c["margin"])
        let worst = (0..<data.count).map { abs(model.margin(data.row($0)) - margins[$0]) }.max() ?? 0
        #expect(worst <= 1e-4, "\(name): margins differ by \(worst)")
    }

    static func histData() throws -> (train: BoostDataset, validation: BoostDataset, fixture: [String: Any]) {
        let t = try Fixture.tensors("boost_hist.safetensors")
        return (BoostDataset(x: try t.float32("x_train"), y: try t.float32("y_train"), features: 8),
                BoostDataset(x: try t.float32("x_val"), y: try t.float32("y_val"), features: 8),
                try Fixture.json("boost_hist.json"))
    }

    @Test("continuous features: within ±0.005 AUC and ±0.01 log loss of xgboost")
    func hist() throws {
        let (train, validation, fixture) = try Self.histData()
        let result = BoostTrainer.train(train, validation: validation, params: BoostParams(trees: 60, maxDepth: 4, eta: 0.1))
        let p = (0..<validation.count).map { result.model.predict(validation.row($0)) }
        let auc = Metrics.auc(p, validation.y), loss = Metrics.logloss(p, validation.y)
        #expect(abs(auc - double(fixture["val_auc"])) <= 0.005, "AUC \(auc) vs xgboost \(double(fixture["val_auc"]))")
        #expect(abs(loss - double(fixture["val_logloss"])) <= 0.01, "log loss \(loss) vs xgboost \(double(fixture["val_logloss"]))")
        #expect(result.rounds.count == 60)
        #expect(abs(result.rounds.last!.validation! - auc) < 1e-12)

        let sampled = fixture["sampled"] as! [String: Any]
        let s = BoostTrainer.train(train, validation: validation, params: BoostParams(trees: 60, maxDepth: 4, eta: 0.1, subsample: 0.8, colsampleByTree: 0.75, seed: 3))
        let ps = (0..<validation.count).map { s.model.predict(validation.row($0)) }
        #expect(abs(Metrics.auc(ps, validation.y) - double(sampled["val_auc"])) <= 0.01)
        let again = BoostTrainer.train(train, validation: validation, params: BoostParams(trees: 60, maxDepth: 4, eta: 0.1, subsample: 0.8, colsampleByTree: 0.75, seed: 3))
        #expect(again.model.encodeXGBoostJSON() == s.model.encodeXGBoostJSON(), "a seed names one model")
    }

    @Test("a warm start appends to xgboost's model and keeps its trees byte for byte")
    func warmStart() throws {
        let (train, validation, fixture) = try Self.histData()
        let warm = fixture["warm"] as! [String: Any]
        let text = warm["model30"] as! String
        let parent = try GBDTModel.decode(xgboostJSON: Data(text.utf8))
        #expect(parent.trees.count == 30)
        let result = BoostTrainer.train(train, validation: validation, params: BoostParams(trees: 10, maxDepth: 4, eta: 0.1), warmStart: parent)
        #expect(result.model.trees.count == 40)
        #expect(result.inheritedTrees == 30)
        #expect(result.model.baseScore == parent.baseScore)
        for i in 0..<30 { #expect(result.model.trees[i].raw == parent.trees[i].raw) }
        #expect(Array(result.model.trees[30...].map(\.id)) == Array(30..<40))
        let encoded = String(decoding: result.model.encodeXGBoostJSON(), as: UTF8.self)
        for tree in parent.trees { #expect(encoded.contains(tree.raw!)) }
        let p = (0..<validation.count).map { result.model.predict(validation.row($0)) }
        #expect(abs(Metrics.auc(p, validation.y) - double(warm["val_auc40"])) <= 0.005)
    }

    @Test("early stopping keeps the best round and truncates to it")
    func earlyStopping() throws {
        let (train, validation, _) = try Self.histData()
        let result = BoostTrainer.train(train, validation: validation, params: BoostParams(trees: 400, maxDepth: 6, eta: 0.3, earlyStoppingRounds: 5))
        let best = try #require(result.bestTreeCount)
        #expect(result.model.trees.count == best)
        #expect(result.rounds.count < 400)
        let scores = result.rounds.compactMap(\.validation)
        let top = scores.max()!
        #expect(abs(scores[best - 1] - top) < 1e-15)
        #expect(scores.firstIndex(of: top)! == best - 1, "the first best round wins")
    }

    @Test("a trained model reads back through Frigate's evaluator with identical predictions")
    func frigateReadsIt() throws {
        let (train, validation, _) = try Self.histData()
        let result = BoostTrainer.train(train, params: BoostParams(trees: 25, maxDepth: 5, eta: 0.2, subsample: 0.9, colsampleByTree: 0.8, seed: 1))
        let json = result.model.encodeXGBoostJSON()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vg-trained-\(UUID().uuidString).json")
        try json.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let frigate = try XGBoostTreeModel(url: file)
        #expect(frigate.numFeatures == 8)
        let decoded = try GBDTModel.decode(xgboostJSON: json)
        #expect(decoded.encodeXGBoostJSON() == json, "decode → encode is the identity on a trained model")
        for i in 0..<validation.count {
            let row = validation.row(i)
            #expect(frigate.predict(row) == result.model.predict(row))
        }
    }

    @Test("a column mask keeps the data's width and grows, node for node, the trees a refit on only its columns grows")
    func columnMask() throws {
        let (train, validation, _) = try Self.histData()
        let mask = [1, 3, 6]
        var params = BoostParams(trees: 40, maxDepth: 4, eta: 0.1, subsample: 0.8, colsampleByTree: 0.8, seed: 3)
        let compact = BoostTrainer.train(PruningStudy.keeping(train, mask), params: params).model
        params.allowedColumns = mask
        let masked = BoostTrainer.train(train, params: params).model
        #expect(masked.featureCount == 8 && compact.featureCount == 3)
        #expect(masked.trees.count == 40 && compact.trees.count == 40)
        for (m, c) in zip(masked.trees, compact.trees) {
            #expect(m.leftChildren == c.leftChildren && m.rightChildren == c.rightChildren && m.parents == c.parents)
            #expect(m.splitConditions == c.splitConditions && m.baseWeights == c.baseWeights)
            #expect(m.lossChanges == c.lossChanges && m.sumHessian == c.sumHessian)
            #expect(m.numFeature == 8 && c.numFeature == 3)
            let splits = (0..<m.nodeCount).filter { m.leftChildren[$0] != -1 }
            #expect(splits.allSatisfy { Int(m.splitIndices[$0]) == mask[Int(c.splitIndices[$0])] }, "a masked split names the compact split's column")
        }
        let used = Set(masked.trees.flatMap { t -> [Int] in (0..<t.nodeCount).filter { t.leftChildren[$0] != -1 }.map { Int(t.splitIndices[$0]) } })
        let allowed: Set<Int> = Set(mask)
        #expect(!used.isEmpty && used.isSubset(of: allowed))
        let differing = (0..<validation.count).filter { i in
            let row = validation.row(i)
            return masked.predict(row) != compact.predict(mask.map { row[$0] })
        }
        #expect(differing.isEmpty, "\(differing.count) validation rows score differently")
        // Eight wide through Frigate's evaluator, as the lens would read it.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vg-masked-\(UUID().uuidString).json")
        try masked.encodeXGBoostJSON().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let frigate = try XGBoostTreeModel(url: file)
        #expect(frigate.numFeatures == 8)
        #expect((0..<validation.count).allSatisfy { frigate.predict(validation.row($0)) == masked.predict(validation.row($0)) })
    }

    @Test("no mask and a mask of every column are one model; the mask is recorded only when set")
    func fullMask() throws {
        let (train, _, _) = try Self.histData()
        var params = BoostParams(trees: 15, maxDepth: 3, eta: 0.2, subsample: 0.8, colsampleByTree: 0.75, seed: 5)
        let plain = BoostTrainer.train(train, params: params).model.encodeXGBoostJSON()
        params.allowedColumns = Array(0..<8)
        #expect(BoostTrainer.train(train, params: params).model.encodeXGBoostJSON() == plain)
        params.allowedColumns = [4]
        let one = BoostTrainer.train(train, params: params).model
        #expect(one.trees.allSatisfy { t in (0..<t.nodeCount).allSatisfy { t.leftChildren[$0] == -1 || t.splitIndices[$0] == 4 } })
        let unset = String(decoding: try JSONEncoder().encode(BoostParams()), as: UTF8.self)
        #expect(!unset.contains("allowedColumns"), "an unmasked recipe encodes as before")
        params.allowedColumns = [0, 2]
        #expect(try JSONDecoder().decode(BoostParams.self, from: JSONEncoder().encode(params)) == params)
    }

    @Test("base_score: the weighted mean at scale_pos_weight 1, a Newton step otherwise")
    func baseScore() throws {
        let (_, plain, weighted) = try Self.exactData()
        let mean = Double(zip(weighted.y, weighted.weight!).map { Double($0) * Double($1) }.reduce(0, +)) / weighted.weight!.map(Double.init).reduce(0, +)
        #expect(abs(BoostTrainer.baseScore(weighted, scalePosWeight: 1) - mean) < 1e-12)
        #expect(BoostTrainer.baseScore(plain, scalePosWeight: 1) == Double(plain.y.reduce(0, +)) / Double(plain.count))
    }
}
