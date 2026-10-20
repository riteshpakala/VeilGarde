//
//  Safetensors.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: Safetensors with no MLX: a reader for the header and any F32, F16, BF16, I32, I16 or U8
//        tensor as a Swift array, and a writer for those dtypes and U32 with a `__metadata__`
//        header.
//        The feature store, the tile caches and every fixture go through here, so the domain
//        layer reads the seed shards and writes its own without touching the GPU.
//  PIN:  Little-endian: an 8-byte header length, the header's JSON, then the data, each tensor
//        at `data_offsets` relative to the data's start. Every range is checked against the file
//        and against its dtype and shape before a byte is read; F16 is widened bit-exactly. The
//        writer sorts tensor names and metadata keys, lays the data out contiguously in that
//        order, and pads the header with spaces to a multiple of 8, so the same tensors always
//        write the same bytes and Python's safetensors accepts the file. `.python` layout writes
//        the bytes Python's safetensors itself writes (tensors by dtype, widest first, then name;
//        each entry's fields as dtype, shape, data_offsets), so a weight file converted here can
//        be byte-identical to one Python exported. The reader is Braid's.
//

import Foundation

public struct SafetensorsFile: Sendable {
    public struct Tensor: Sendable, Equatable {
        public var name: String
        /// "I32", "F16", "F32", … as the header names it.
        public var dtype: String
        public var shape: [Int]
        /// The tensor's bytes, relative to the file's first byte.
        public var bytes: Range<Int>

        public var count: Int { shape.reduce(1, *) }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case short(String)
        case header(String)
        case missing(String)
        case dtype(name: String, found: String, expected: String)
        case bounds(String)

        public var description: String {
            switch self {
            case .short(let detail): return "safetensors: the file is too short (\(detail))"
            case .header(let detail): return "safetensors: the header is not valid (\(detail))"
            case .missing(let name): return "safetensors: no tensor named \(name)"
            case .dtype(let name, let found, let expected): return "safetensors: \(name) is \(found), not \(expected)"
            case .bounds(let detail): return "safetensors: \(detail)"
            }
        }
    }

    public let url: URL?
    public let data: Data
    public let tensors: [String: Tensor]
    public let metadata: [String: String]

    /// Reads (maps) the file at `url`.
    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped), url: url)
    }

    public init(data: Data, url: URL? = nil) throws {
        self.url = url
        self.data = data
        guard data.count >= 8 else { throw Failure.short("\(data.count) bytes, no header length") }
        let length = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) }
        guard length <= UInt64(data.count - 8) else { throw Failure.short("a \(length)-byte header in \(data.count) bytes") }
        let start = data.startIndex
        let headerData = data.subdata(in: (start + 8)..<(start + 8 + Int(length)))
        guard let object = try? JSONSerialization.jsonObject(with: headerData), let header = object as? [String: Any] else {
            throw Failure.header("not a JSON object")
        }
        let base = 8 + Int(length)
        var tensors: [String: Tensor] = [:]
        var metadata: [String: String] = [:]
        for (name, value) in header {
            if name == "__metadata__" {
                for (key, entry) in (value as? [String: Any]) ?? [:] { metadata[key] = entry as? String ?? "\(entry)" }
                continue
            }
            guard let entry = value as? [String: Any], let dtype = entry["dtype"] as? String,
                  let shape = (entry["shape"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }),
                  let offsets = (entry["data_offsets"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }), offsets.count == 2
            else { throw Failure.header("tensor \(name) has no dtype, shape or data_offsets") }
            guard offsets[0] >= 0, offsets[0] <= offsets[1], base + offsets[1] <= data.count else {
                throw Failure.bounds("\(name) spans \(offsets[0])..<\(offsets[1]) past the file's \(data.count - base) data bytes")
            }
            let tensor = Tensor(name: name, dtype: dtype, shape: shape, bytes: (base + offsets[0])..<(base + offsets[1]))
            if let width = Self.width(dtype), tensor.count * width != tensor.bytes.count {
                throw Failure.bounds("\(name) is \(dtype) \(shape) but holds \(tensor.bytes.count) bytes")
            }
            tensors[name] = tensor
        }
        self.tensors = tensors
        self.metadata = metadata
    }

    /// Bytes per element of the dtypes this reader knows; nil for the rest.
    static func width(_ dtype: String) -> Int? {
        switch dtype {
        case "I32", "F32", "U32": return 4
        case "F16", "BF16", "I16", "U16": return 2
        case "I64", "F64", "U64": return 8
        case "U8", "I8", "BOOL": return 1
        default: return nil
        }
    }

    public func tensor(_ name: String) throws -> Tensor {
        guard let tensor = tensors[name] else { throw Failure.missing(name) }
        return tensor
    }

    public var names: [String] { tensors.keys.sorted() }

    /// Copies a tensor's bytes into a new array of `T`, which must be the dtype's width (the host is
    /// little-endian, as every Apple-silicon Mac is).
    private func copy<T>(_ tensor: Tensor, as type: T.Type) -> [T] {
        let count = tensor.count
        if count == 0 { return [] }
        return data.withUnsafeBytes { raw in
            [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                let source = raw.baseAddress!.advanced(by: tensor.bytes.lowerBound)
                memcpy(buffer.baseAddress!, source, count * MemoryLayout<T>.stride)
                initialized = count
            }
        }
    }

    /// An F32 tensor, or an F16 or BF16 one widened, flattened.
    public func float32(_ name: String) throws -> [Float] {
        let tensor = try tensor(name)
        switch tensor.dtype {
        case "F32":
            return copy(tensor, as: Float.self)
        case "F16":
            return copy(tensor, as: UInt16.self).map(Self.widen)
        case "BF16":
            return copy(tensor, as: UInt16.self).map { Float(bitPattern: UInt32($0) << 16) }
        case "F64":
            return copy(tensor, as: Double.self).map { Float($0) }
        default:
            throw Failure.dtype(name: name, found: tensor.dtype, expected: "F32, F16 or BF16")
        }
    }

    /// An I32 tensor, flattened.
    public func int32(_ name: String) throws -> [Int32] {
        let tensor = try tensor(name)
        switch tensor.dtype {
        case "I32": return copy(tensor, as: Int32.self)
        case "I16": return copy(tensor, as: Int16.self).map(Int32.init)
        case "U8", "BOOL": return copy(tensor, as: UInt8.self).map(Int32.init)
        case "I64": return copy(tensor, as: Int64.self).map { Int32(truncatingIfNeeded: $0) }
        default: throw Failure.dtype(name: name, found: tensor.dtype, expected: "I32")
        }
    }

    /// An I16 tensor, flattened.
    public func int16(_ name: String) throws -> [Int16] {
        let tensor = try tensor(name)
        guard tensor.dtype == "I16" else { throw Failure.dtype(name: name, found: tensor.dtype, expected: "I16") }
        return copy(tensor, as: Int16.self)
    }

    /// A U8 (or BOOL) tensor, flattened.
    public func uint8(_ name: String) throws -> [UInt8] {
        let tensor = try tensor(name)
        guard tensor.dtype == "U8" || tensor.dtype == "BOOL" else { throw Failure.dtype(name: name, found: tensor.dtype, expected: "U8") }
        return copy(tensor, as: UInt8.self)
    }

    /// A U32 tensor (MLX's packed quantized weights), flattened.
    public func uint32(_ name: String) throws -> [UInt32] {
        let tensor = try tensor(name)
        guard tensor.dtype == "U32" else { throw Failure.dtype(name: name, found: tensor.dtype, expected: "U32") }
        return copy(tensor, as: UInt32.self)
    }

    /// A tensor's raw little-endian bytes, whatever its dtype.
    public func bytes(_ name: String) throws -> Data {
        let range = try tensor(name).bytes
        return data.withUnsafeBytes { Data($0[range]) }
    }

    /// IEEE half to single, exactly.
    public static func widen(_ half: UInt16) -> Float {
        let sign = UInt32(half & 0x8000) << 16
        let exponent = UInt32((half >> 10) & 0x1F)
        let mantissa = UInt32(half & 0x03FF)
        if exponent == 0 {
            // Zero or subnormal: mantissa × 2^-24, exact in single precision.
            let magnitude = Float(mantissa) * Float(bitPattern: 0x3380_0000)
            return sign == 0 ? magnitude : -magnitude
        }
        if exponent == 0x1F { return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13)) }
        return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
    }

    /// The SHA-256 of the whole file.
    public var sha256: String { ContentHash.sha256Hex(data) }
}

/// Writes safetensors files: sorted names, contiguous data, a padded header.
public enum SafetensorsWriter {
    public enum Payload: Sendable, Equatable {
        case float32([Float])
        case float16Bits([UInt16])
        case int32([Int32])
        case int16([Int16])
        case uint8([UInt8])
        case uint32([UInt32])

        public var dtype: String {
            switch self {
            case .float32: return "F32"
            case .float16Bits: return "F16"
            case .int32: return "I32"
            case .int16: return "I16"
            case .uint8: return "U8"
            case .uint32: return "U32"
            }
        }

        /// Python safetensors' order: wider dtypes first (its Dtype enum, descending).
        var pythonRank: Int {
            switch self {
            case .float32: return 7
            case .uint32: return 6
            case .int32: return 5
            case .float16Bits: return 3
            case .int16: return 2
            case .uint8: return 1
            }
        }

        public var count: Int {
            switch self {
            case .float32(let v): return v.count
            case .float16Bits(let v): return v.count
            case .int32(let v): return v.count
            case .int16(let v): return v.count
            case .uint8(let v): return v.count
            case .uint32(let v): return v.count
            }
        }

        func append(to data: inout Data) {
            switch self {
            case .float32(let v): v.withUnsafeBytes { data.append(contentsOf: $0) }
            case .float16Bits(let v): v.withUnsafeBytes { data.append(contentsOf: $0) }
            case .int32(let v): v.withUnsafeBytes { data.append(contentsOf: $0) }
            case .int16(let v): v.withUnsafeBytes { data.append(contentsOf: $0) }
            case .uint8(let v): data.append(contentsOf: v)
            case .uint32(let v): v.withUnsafeBytes { data.append(contentsOf: $0) }
            }
        }

        var byteCount: Int { count * (SafetensorsFile.width(dtype) ?? 1) }
    }

    public struct Entry: Sendable {
        public var name: String
        public var shape: [Int]
        public var payload: Payload

        public init(_ name: String, shape: [Int], _ payload: Payload) {
            self.name = name
            self.shape = shape
            self.payload = payload
        }
    }

    /// How the header is laid out: VeilGarde's (sorted JSON throughout) or Python's own.
    public enum Layout: Sendable { case sorted, python }

    public static func encode(_ entries: [Entry], metadata: [String: String] = [:], layout: Layout = .sorted) throws -> Data {
        if layout == .python { return try encodePython(entries, metadata: metadata) }
        var header: [String: Any] = [:]
        if !metadata.isEmpty { header["__metadata__"] = metadata }
        var offset = 0
        let sorted = entries.sorted { $0.name < $1.name }
        for entry in sorted {
            guard entry.name != "__metadata__", header[entry.name] == nil else {
                throw SafetensorsFile.Failure.header("tensor name \(entry.name) repeats or is reserved")
            }
            guard entry.shape.reduce(1, *) == entry.payload.count else {
                throw SafetensorsFile.Failure.bounds("\(entry.name) has shape \(entry.shape) but \(entry.payload.count) values")
            }
            header[entry.name] = ["dtype": entry.payload.dtype, "shape": entry.shape, "data_offsets": [offset, offset + entry.payload.byteCount]] as [String: Any]
            offset += entry.payload.byteCount
        }
        var json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])
        while (8 + json.count) % 8 != 0 { json.append(0x20) }
        var out = Data(capacity: 8 + json.count + offset)
        var length = UInt64(json.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(json)
        for entry in sorted { entry.payload.append(to: &out) }
        return out
    }

    public static func write(_ entries: [Entry], metadata: [String: String] = [:], layout: Layout = .sorted, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(entries, metadata: metadata, layout: layout).write(to: url, options: .atomic)
    }

    /// The bytes Python's safetensors (0.4+) writes for these tensors: data ordered by dtype,
    /// widest first, then by name; the header in that order with each entry's fields as dtype,
    /// shape, data_offsets; metadata, when given, first (keys sorted here); spaces to 8 bytes.
    static func encodePython(_ entries: [Entry], metadata: [String: String]) throws -> Data {
        func quoted(_ s: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
            return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
        }
        let ordered = entries.sorted { ($0.payload.pythonRank, $1.name) > ($1.payload.pythonRank, $0.name) }
        var names = Set<String>()
        var parts: [String] = []
        if !metadata.isEmpty {
            parts.append("\"__metadata__\":{" + (try metadata.keys.sorted().map { "\(try quoted($0)):\(try quoted(metadata[$0]!))" }).joined(separator: ",") + "}")
        }
        var offset = 0
        for entry in ordered {
            guard entry.name != "__metadata__", names.insert(entry.name).inserted else {
                throw SafetensorsFile.Failure.header("tensor name \(entry.name) repeats or is reserved")
            }
            guard entry.shape.reduce(1, *) == entry.payload.count else {
                throw SafetensorsFile.Failure.bounds("\(entry.name) has shape \(entry.shape) but \(entry.payload.count) values")
            }
            let end = offset + entry.payload.byteCount
            parts.append("\(try quoted(entry.name)):{\"dtype\":\"\(entry.payload.dtype)\",\"shape\":[\(entry.shape.map(String.init).joined(separator: ","))],\"data_offsets\":[\(offset),\(end)]}")
            offset = end
        }
        var json = Data(("{" + parts.joined(separator: ",") + "}").utf8)
        while json.count % 8 != 0 { json.append(0x20) }
        var out = Data(capacity: 8 + json.count + offset)
        var length = UInt64(json.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(json)
        for entry in ordered { entry.payload.append(to: &out) }
        return out
    }
}
