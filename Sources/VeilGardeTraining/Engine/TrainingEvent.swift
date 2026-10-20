//
//  TrainingEvent.swift
//  VeilGardeTraining
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: What the engine reports while it trains: a model's stage beginning, the progress lines
//        `veilgarde train` prints to stderr, and each model's metrics once it is written. Every
//        event is also a row of the candidate's runs.jsonl.
//

import Foundation

public enum TrainingEvent: Sendable, Equatable {
    case stage(model: String, TrainingStage)
    case note(String)
    case metrics(model: String, json: String)

    /// The text a terminal prints for the event; nil for a stage boundary.
    public var line: String? {
        switch self {
        case .note(let text): return text
        case .metrics(let model, _): return "\(model): metrics written"
        case .stage: return nil
        }
    }

    struct Row: Codable {
        var time: Date
        var kind: String
        var model: String?
        var stage: String?
        var text: String?
        var metrics: String?
    }

    var row: Row {
        switch self {
        case .stage(let model, let stage): return Row(time: Date(), kind: "stage", model: model, stage: stage.rawValue)
        case .note(let text): return Row(time: Date(), kind: "note", text: text)
        case .metrics(let model, let json): return Row(time: Date(), kind: "metrics", model: model, metrics: json)
        }
    }
}
