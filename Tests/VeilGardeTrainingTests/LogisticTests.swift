//
//  LogisticTests.swift
//  VeilGardeTrainingTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The sklearn-parity solvers. StandardScaler + LogisticNewton reach sklearn's optimum for
//        the three head recipes (balanced C 0.5, unweighted C 0.5, unweighted C 1) within 1e-5,
//        and sit within 2e-3 of the reference fits made at lbfgs's default tolerance.
//

import Foundation
import Testing
@testable import VeilGardeTraining

@Suite("Logistic solvers")
struct LogisticTests {
    @Test("the head recipes reach sklearn's optimum", arguments: ["balanced_c05", "none_c05", "none_c1"])
    func heads(_ name: String) throws {
        let t = try Fixture.tensors("lr_fixture.safetensors")
        let x = try t.float32("x"), y = try t.float32("y").map(Double.init)
        let d = 48, n = y.count
        let c = (try Fixture.json("lr_fixture.json")["cases"] as! [[String: Any]]).first { $0["name"] as! String == name }!
        let all = Array(0..<n)
        let scaler = StandardScaler.fit(x, d: d, rows: all)
        #expect(maxAbs(scaler.mean, doubles(c["mean"])) < 1e-9)
        #expect(maxAbs(scaler.scale, doubles(c["scale"])) < 1e-9)
        #expect(scaler.scale[5] == 1)
        let z = scaler.transform(x, d: d, rows: all)
        let fit = LogisticNewton.fit(x: z, y: y, d: d, C: double(c["C"]), classWeight: c["class_weight"] as! String == "balanced" ? .balanced : .none)
        #expect(maxAbs(fit.coef, doubles(c["coef"])) < 1e-5, "\(name): coef")
        #expect(abs(fit.intercept - double(c["intercept"])) < 1e-5, "\(name): intercept")
        #expect(maxAbs(fit.coef, doubles(c["reference_coef"])) < 2e-3, "\(name): distance to the reference lbfgs fit")
        let p = (0..<n).map { fit.probability(z[($0 * d)..<(($0 + 1) * d)]) }
        #expect(maxAbs(p, doubles(c["p"])) < 1e-6)
        #expect(fit.coef[5] == 0)
    }
}
