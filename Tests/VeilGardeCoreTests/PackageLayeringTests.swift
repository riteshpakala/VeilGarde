//
//  PackageLayeringTests.swift
//  VeilGardeCoreTests
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The manifest and the sources to the package's rules, as text over Package.swift,
//        Sources/, Tests/ and Examples/: exactly four products; the layer table (which target
//        may depend on which); MLX only through Frigate, each Frigate module imported only by a
//        target that lists its product; Core on Foundation and Crypto alone; nothing imports
//        MLXLLM, MLXLMCommon, AppKit or UIKit; nothing re-declares a Frigate function; no type is
//        named like a module; Bundle.module in one file; every Swift file opens with its name, its
//        target, its license and its WHAT; every script, manifest and site script names GPL-3.0.
//

import Foundation
import Testing

private let repoRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
    return url.deletingLastPathComponent()
}()

/// The identifier every source file carries (LICENSE holds the text).
private let license = "SPDX-License-Identifier: GPL-3.0-only"

private func text(_ relative: String) throws -> String {
    try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
}

private func swiftFiles(under relative: String) -> [URL] {
    let root = repoRoot.appendingPathComponent(relative)
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    return walker.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" && !$0.path.contains("/.build/") && !$0.path.contains("/.work/") && !$0.lastPathComponent.hasPrefix("._") }
        .sorted { $0.path < $1.path }
}

/// One `.target(`, `.executableTarget(` or `.testTarget(` block of the manifest, read as text.
private struct ManifestTarget {
    var name: String
    var kind: String
    var targets: Set<String>
    var products: Set<String>
}

private func manifestTargets() throws -> [ManifestTarget] {
    let manifest = try text("Package.swift")
    let opener = try NSRegularExpression(pattern: #"\.(target|executableTarget|testTarget)\(\s*name:\s*"(\w+)""#)
    let product = try NSRegularExpression(pattern: #"\.product\(name:\s*"(\w+)",\s*package:\s*"([\w-]+)"\)"#)
    let quoted = try NSRegularExpression(pattern: #""(\w+)""#)
    let ns = manifest as NSString
    let matches = opener.matches(in: manifest, range: NSRange(location: 0, length: ns.length))
    var result: [ManifestTarget] = []
    for (i, match) in matches.enumerated() {
        let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
        let block = ns.substring(with: NSRange(location: match.range.location, length: end - match.range.location))
        let kind = ns.substring(with: match.range(at: 1))
        let name = ns.substring(with: match.range(at: 2))
        var dependencies = ""
        if let start = block.range(of: "dependencies:") {
            let rest = block[start.upperBound...]
            if let close = rest.firstIndex(of: "]") { dependencies = String(rest[..<close]) }
        }
        let depNS = dependencies as NSString
        var products: Set<String> = []
        for found in product.matches(in: dependencies, range: NSRange(location: 0, length: depNS.length)) {
            products.insert(depNS.substring(with: found.range(at: 1)))
        }
        let stripped = product.stringByReplacingMatches(in: dependencies, range: NSRange(location: 0, length: depNS.length), withTemplate: "")
        let strippedNS = stripped as NSString
        var targets: Set<String> = []
        for found in quoted.matches(in: stripped, range: NSRange(location: 0, length: strippedNS.length)) {
            targets.insert(strippedNS.substring(with: found.range(at: 1)))
        }
        result.append(ManifestTarget(name: name, kind: kind, targets: targets, products: products))
    }
    return result
}

/// The module a Frigate product builds (they share a name except the hub).
private func module(ofProduct product: String) -> String { product == "FrigateHub" ? "Hub" : product }

private let frigateModules: Set<String> = [
    "Frigate", "MLX", "MLXNN", "MLXFFT", "MLXAccelerate", "MLXOptimizers", "MLXRandom", "MLXLinalg", "MLXFast",
    "Hub", "Tokenizers", "MLXLLM", "MLXVLM", "MLXLMCommon", "MLXEmbedders", "FrigateBridge", "FrigateParallel",
]

private let systemModules: Set<String> = [
    "Foundation", "Dispatch", "Darwin", "CoreGraphics", "ImageIO", "UniformTypeIdentifiers", "CoreFoundation", "os", "AppKit",
    // Apple's Accelerate (CPU BLAS for the linear solvers), not Frigate's MLX-backed MLXAccelerate.
    "Accelerate",
]

private func imports(in body: String) -> [String] {
    body.split(separator: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["@_exported import ", "@testable import ", "import "] where trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count).split(separator: " ").first ?? "")
        }
        return nil
    }
}

@Suite("Package layering")
struct PackageLayeringTests {
    /// Who may depend on whom. A new edge is a design change: change this table on purpose.
    static let layers: [String: Set<String>] = [
        "VeilGardeCore": [],
        "VeilGardeLens": ["VeilGardeCore"],
        "VeilGardeInference": ["VeilGardeLens"],
        "VeilGardeTraining": ["VeilGardeLens"],
        "VeilGardeFlywheel": ["VeilGardeTraining", "VeilGardeInference"],
        "VeilWatermark": ["VeilGardeLens"],
        "VeilGarde": ["VeilGardeInference", "VeilGardeTraining", "VeilGardeFlywheel", "VeilWatermark"],
        "VeilGardeCLI": ["VeilGarde"],
    ]

    @Test("four products: VeilGarde, VeilGardeInference, VeilWatermark and the veilgarde executable")
    func products() throws {
        let manifest = try text("Package.swift")
        #expect(manifest.contains(".library(name: \"VeilGarde\""))
        #expect(manifest.contains(".library(name: \"VeilGardeInference\""))
        #expect(manifest.contains(".library(name: \"VeilWatermark\""))
        #expect(manifest.contains(".executable(name: \"veilgarde\""))
        #expect(manifest.components(separatedBy: ".library(name:").count == 4)
        #expect(manifest.components(separatedBy: ".executable(name:").count == 2)
    }

    @Test("the source targets and their edges are the layer table")
    func layerTable() throws {
        let sources = try manifestTargets().filter { $0.kind != "testTarget" }
        #expect(Set(sources.map(\.name)) == Set(Self.layers.keys))
        for target in sources {
            #expect(target.targets == Self.layers[target.name], "\(target.name) depends on \(target.targets.sorted())")
        }
    }

    @Test("MLX comes only from Frigate: no mlx-swift package, Frigate taken by path")
    func mlxThroughFrigate() throws {
        let manifest = try text("Package.swift")
        let url = try NSRegularExpression(pattern: #"\.package\(url:\s*"([^"]+)""#)
        let ns = manifest as NSString
        let urls = url.matches(in: manifest, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        #expect(!urls.isEmpty)
        for found in urls {
            #expect(!found.contains("ml-explore") && !found.contains("mlx"), "Package.swift takes \(found) by URL")
        }
        #expect(manifest.contains(".package(path: frigate)"))
    }

    @Test("every import sits inside its target's declared dependencies")
    func importsAreDeclared() throws {
        let targets = try manifestTargets()
        let byName = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) })
        func closure(_ name: String) -> Set<String> {
            var seen: Set<String> = []
            var stack = [name]
            while let next = stack.popLast() {
                for dependency in byName[next]?.targets ?? [] where !seen.contains(dependency) {
                    seen.insert(dependency)
                    stack.append(dependency)
                }
            }
            return seen
        }
        for target in targets where target.kind != "testTarget" {
            let directProducts = Set(target.products.map(module(ofProduct:)))
            let layer = closure(target.name)
            let allowedSystem = target.name == "VeilGardeCore" ? ["Foundation", "Crypto"] : systemModules.union(["Crypto"])
            for file in swiftFiles(under: "Sources/\(target.name)") {
                let body = try String(contentsOf: file, encoding: .utf8)
                for name in imports(in: body) {
                    if frigateModules.contains(name) {
                        #expect(directProducts.contains(name), "\(target.name)/\(file.lastPathComponent) imports \(name) without listing its Frigate product")
                    } else if name.hasPrefix("VeilGarde") || name == "VeilWatermark" {
                        #expect(layer.contains(name), "\(target.name)/\(file.lastPathComponent) imports \(name), above its layer")
                    } else if name == "ArgumentParser" {
                        #expect(target.name == "VeilGardeCLI", "\(file.lastPathComponent) imports ArgumentParser outside the CLI")
                    } else {
                        #expect(allowedSystem.contains(name), "\(target.name)/\(file.lastPathComponent) imports \(name)")
                    }
                }
            }
        }
    }

    @Test("nothing imports MLXLLM, MLXLMCommon, UIKit or SwiftUI, and AppKit only to decode images")
    func noForbiddenImports() throws {
        for file in swiftFiles(under: "Sources") + swiftFiles(under: "Examples/Sources") {
            let names = Set(imports(in: try String(contentsOf: file, encoding: .utf8)))
            for forbidden in ["MLXLLM", "MLXLMCommon", "UIKit", "SwiftUI"] {
                #expect(!names.contains(forbidden), "\(file.lastPathComponent) imports \(forbidden)")
            }
            // NSImage is the decoder every shipped artifact was computed through (ImageDecoding's PIN).
            if names.contains("AppKit") {
                #expect(file.path.hasSuffix("Sources/VeilGardeLens/Image/ImageDecoding.swift"), "\(file.lastPathComponent) imports AppKit")
            }
        }
    }

    @Test("nothing re-declares a function Frigate already provides")
    func noFrigateReimplementation() throws {
        let frigateFunctions = [
            "perspectiveWarp", "getPerspectiveTransform", "getPerspectiveTransformD", "invertMatrix3x3", "invertMatrix3x3D",
            "gaussianBlur", "sobelGradients", "filter2D", "batchedFilter2D", "batchedSobelGradients", "batchedGaussianBlur",
            "reflect101Index", "reflectPad101", "buildBicubicWarpTapsHost", "buildBicubicWarpTable", "applyWarpTable",
            "spectralDistance", "kmeans", "nearestCentroids", "pairwiseSquaredDistances", "centroidDistanceTable", "gaussianElimination",
        ]
        let declaration = try NSRegularExpression(pattern: #"\bfunc\s+(\w+)\s*[(<]"#)
        for file in swiftFiles(under: "Sources") {
            let body = try String(contentsOf: file, encoding: .utf8)
            let ns = body as NSString
            for match in declaration.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1))
                #expect(!frigateFunctions.contains(name), "\(file.lastPathComponent) declares \(name), which Frigate provides")
            }
        }
    }

    @Test("no type is named like a module")
    func names() throws {
        let modules = Set(Self.layers.keys).union(frigateModules).union(["Crypto", "ArgumentParser"])
        let declaration = try NSRegularExpression(pattern: #"\b(struct|class|enum|actor|protocol|typealias)\s+(\w+)"#)
        for file in swiftFiles(under: "Sources") {
            let body = try String(contentsOf: file, encoding: .utf8)
            let ns = body as NSString
            for match in declaration.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 2))
                #expect(!modules.contains(name), "\(file.lastPathComponent) declares a type named \(name)")
            }
        }
    }

    @Test("Bundle.module is written in two files: the shipped bundle and the flywheel's resources")
    func bundleModuleInOneFile() throws {
        for file in swiftFiles(under: "Sources") {
            let body = try String(contentsOf: file, encoding: .utf8)
            guard body.contains("Bundle.module") else { continue }
            #expect(file.path.hasSuffix("Sources/VeilGardeInference/Bundle/ShippedBundle.swift") || file.path.hasSuffix("Sources/VeilGardeFlywheel/FlywheelResources.swift"),
                    "\(file.lastPathComponent) reads Bundle.module")
        }
    }

    @Test("every Swift file opens with its name, its target, its license and a WHAT")
    func headers() throws {
        for root in ["Sources", "Tests", "Examples/Sources"] {
            for file in swiftFiles(under: root) {
                let body = try String(contentsOf: file, encoding: .utf8)
                let target = file.deletingLastPathComponent().pathComponents
                    .drop { $0 != (root == "Examples/Sources" ? "Sources" : root) }.dropFirst().first ?? ""
                let header = "//\n//  \(file.lastPathComponent)\n//  \(target)\n//  \(license)\n//\n//  WHAT:"
                #expect(body.hasPrefix(header), "\(file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")) does not open with its WHAT header")
            }
        }
    }

    @Test("the manifests, every script and the site's code name the GPL-3.0 at the top")
    func licenses() throws {
        for manifest in ["Package.swift", "Examples/Package.swift"] {
            let lines = try text(manifest).split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines.count > 1 && lines[1] == "// \(license)", "\(manifest) names its license on its second line")
        }
        var scripts: [String] = ["build-metallib.sh", "Examples/run.sh"]
        for folder in ["Scripts", "Docs/site/src", "Docs/site/js"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: repoRoot.appendingPathComponent(folder).path)) ?? []
            scripts += names.filter { !$0.hasPrefix(".") && ["sh", "py", "js", "command"].contains(URL(fileURLWithPath: $0).pathExtension) }.map { "\(folder)/\($0)" }
        }
        #expect(scripts.count >= 13)
        for script in scripts.sorted() {
            let top = try text(script).split(separator: "\n", omittingEmptySubsequences: false).prefix(16)
            #expect(top.contains { $0.hasSuffix(license) }, "\(script) names its license near the top")
        }
    }
}
