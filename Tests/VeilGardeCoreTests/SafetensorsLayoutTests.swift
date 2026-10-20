//
//  SafetensorsLayoutTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The writer's python layout writes the bytes Python's safetensors writes: a committed
//        file from safetensors 0.5 (six dtypes) is reproduced exactly, and so, when this Mac
//        has them, are the shipped weight files exported from Python (the noiseprint and DINOv2-small),
//        re-encoded from their own tensors. That is what lets an import be byte-identical.
//

import Foundation
import Testing
import VeilGardeCore

@Suite("Safetensors: Python's own layout")
struct SafetensorsLayoutTests {
    @Test("a file Python's safetensors wrote is reproduced byte for byte")
    func fixture() throws {
        let entries: [SafetensorsWriter.Entry] = [
            .init("b_u8", shape: [5], .uint8([0, 1, 127, 254, 255])),
            .init("s_i16", shape: [2], .int16([-300, 300])),
            .init("h_f16", shape: [3], .float16Bits([0x3C00, 0xC000, 0x3800])),
            .init("m_i32", shape: [1], .int32([-7])),
            .init("a_u32", shape: [2], .uint32([1, 4_294_967_295])),
            .init("z_f32", shape: [1], .float32([-0.0])),
            .init("w_f32", shape: [2, 3], .float32([0, 1.5, -2, 3.25, 1e-3, 7])),
        ]
        let expected = try Data(contentsOf: Fixture.url("python_layout.safetensors"))
        #expect(try SafetensorsWriter.encode(entries, layout: .python) == expected)
        #expect(try SafetensorsWriter.encode(entries.reversed(), layout: .python) == expected, "the order the entries come in does not matter")
        let read = try SafetensorsFile(data: expected)
        #expect(try read.uint32("a_u32") == [1, 4_294_967_295])
        #expect(try read.bytes("b_u8") == Data([0, 1, 127, 254, 255]))
    }

    /// A shipped weight file exported with Python's safetensors, when this Mac has one.
    static func shipped(_ name: String) -> URL? {
        var folders: [URL] = []
        if let named = ProcessInfo.processInfo.environment["VEILGARDE_WEIGHTS"] { folders.append(URL(fileURLWithPath: named)) }
        if let area = WorkArea.resolve() { folders.append(area.weights) }
        return folders.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test("the shipped weights re-encode to their own bytes", arguments: ["noiseprint_v1.safetensors", "dinov2_small.safetensors"])
    func shippedFiles(_ name: String) throws {
        guard let url = Self.shipped(name) else { return }
        let file = try SafetensorsFile(url: url)
        let entries = try file.names.map { SafetensorsWriter.Entry($0, shape: try file.tensor($0).shape, .float32(try file.float32($0))) }
        let data = try SafetensorsWriter.encode(entries, layout: .python)
        #expect(data.count == file.data.count)
        #expect(data == file.data, "\(name) re-encoded differs from the file")
    }
}
