//
//  BundleDerivation.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: A measurement variant of a bundle, made the same way every time: the parent's artifacts
//        copied into a candidate, the combiner edited (its noiseprint term removed, or a weight
//        set), the edited file written and re-pinned, and the edit recorded in the manifest's
//        history and in a derive.json beside it. The hand-made variants of the pruning study,
//        made reproducible.
//  PIN:  Only the edits a study needs: combiner.w_np=null (the key leaves, so the noiseprint does not
//        run), and combiner.w_np, combiner.w_rescue or combiner.w_gen[k] set to a finite value ≥ 0.
//        Every other key and value of the file is kept; the edited file must decode as a
//        StackCombiner holding the edit, and the candidate verifies after. A derived bundle is for
//        measurement: nothing here promotes it.
//

import Foundation
import VeilGardeCore

/// One edit of a combiner file.
public enum CombinerEdit: Sendable, Equatable, CustomStringConvertible {
    /// combiner.w_np=null: the noiseprint term is gone and the noiseprint does not run.
    case removeNoiseprint
    /// combiner.<field>[=index]=value, for w_np, w_rescue and w_gen.
    case set(field: String, index: Int?, value: Double)

    public static func parse(_ text: String) throws -> CombinerEdit {
        let usage = VeilGardeFailure.usage("an edit is combiner.w_np=null, or combiner.w_np, combiner.w_rescue or combiner.w_gen[0-2] set to a value ≥ 0, not \(text)")
        let parts = text.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].hasPrefix("combiner.") else { throw usage }
        var field = String(parts[0].dropFirst("combiner.".count))
        var index: Int? = nil
        if let open = field.firstIndex(of: "["), field.hasSuffix("]") {
            guard let i = Int(field[field.index(after: open)..<field.index(before: field.endIndex)]) else { throw usage }
            index = i
            field = String(field[..<open])
        }
        if field == "w_np", index == nil, parts[1] == "null" { return .removeNoiseprint }
        guard let value = Double(parts[1]), value.isFinite, value >= 0 else { throw usage }
        switch field {
        case "w_np", "w_rescue": guard index == nil else { throw usage }
        case "w_gen": guard let i = index, (0..<3).contains(i) else { throw usage }
        default: throw usage
        }
        return .set(field: field, index: index, value: value)
    }

    public var description: String {
        switch self {
        case .removeNoiseprint: return "combiner.w_np=null"
        case let .set(field, index, value): return "combiner.\(field)\(index.map { "[\($0)]" } ?? "")=\(value)"
        }
    }
}

/// What a derived bundle came from and what was changed, written beside its manifest.
public struct DerivationRecord: Codable, Sendable, Equatable {
    public var id: String
    public var parent: String
    public var parentManifestSHA256: String
    public var parentCombinerSHA256: String
    public var combinerSHA256: String
    public var edits: [String]
    public var note: String
    public var date: Date
    public var coreVersion: String
}

public enum BundleDerivation {
    public static func derive(id: String, in area: WorkArea, from parent: ModelBundle, edits: [CombinerEdit], note: String,
                              replacing: Bool = false) throws -> CandidateBundle {
        guard !edits.isEmpty else { throw VeilGardeFailure.usage("a derived bundle needs at least one edit") }
        guard let entry = parent.manifest.artifact(.combiner), let url = parent.url(.combiner) else {
            throw VeilGardeFailure.missing("the bundle at \(parent.root.path) has no combiner to edit")
        }
        let original = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw VeilGardeFailure.data("the combiner \(entry.file) is not a JSON object")
        }
        for edit in edits {
            switch edit {
            case .removeNoiseprint:
                object.removeValue(forKey: "w_np")
                if var inputs = object["inputs"] as? [String] { inputs.removeAll { $0 == "noiseprint" }; object["inputs"] = inputs }
            case let .set(field, index, value):
                if let index {
                    guard var list = object[field] as? [Double], index < list.count else { throw VeilGardeFailure.data("the combiner has no \(field)[\(index)]") }
                    list[index] = value
                    object[field] = list
                } else {
                    object[field] = value
                }
            }
        }
        let summary = edits.map(\.description).joined(separator: ", ")
        object["note"] = ((object["note"] as? String).map { $0 + " " } ?? "") + "Derived for measurement: \(summary)."
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let combiner = try JSONDecoder().decode(StackCombiner.self, from: data)
        for edit in edits {
            switch edit {
            case .removeNoiseprint:
                guard combiner.wNp == nil else { throw VeilGardeFailure.internalError("the derived combiner still reads w_np") }
            case let .set(field, index, value):
                let now: Float? = field == "w_np" ? combiner.wNp : field == "w_rescue" ? combiner.wRescue : index.flatMap { combiner.wGen.indices.contains($0) ? combiner.wGen[$0] : nil }
                guard now == Float(value) else { throw VeilGardeFailure.internalError("the derived combiner does not hold \(edit)") }
            }
        }
        let parentManifest = ContentHash.sha256Hex(try JSONCoding.prettyEncoder().encode(parent.manifest))
        let combinerSHA = ContentHash.sha256Hex(data)
        var candidate = try CandidateBundle.create(id: id, in: area, from: parent, replacing: replacing)
        try candidate.derive(data, as: entry.file, role: .combiner, source: "research: \(id)", parentSHA256: entry.sha256, events: [
            BundleEvent(date: Date(), kind: .seed, slot: "*", note: "derived from \(parent.root.path), manifest \(parentManifest.prefix(12))"),
            BundleEvent(date: Date(), kind: .seed, slot: "combiner", fromSHA256: entry.sha256, toSHA256: combinerSHA, note: "\(summary): \(note); measurement only"),
        ])
        try candidate.write(DerivationRecord(id: id, parent: parent.root.path, parentManifestSHA256: parentManifest, parentCombinerSHA256: entry.sha256,
                                             combinerSHA256: combinerSHA, edits: edits.map(\.description), note: note, date: Date(),
                                             coreVersion: VeilGardeVersion.string), as: "derive.json")
        try candidate.verify()
        return candidate
    }
}
