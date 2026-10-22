//
//  Capture.swift
//  VeilGardeInference
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The capture member: the camera-capture signature as measured, the Nyquist peak a sensor's
//        Bayer mosaic leaves, whether the image is large enough to read it, and whether it is
//        present. It measures rather than scores, so it has no P(AI); a present signature is a
//        real camera's, and the combiner silences the generated-side evidence on it.
//  PIN:  valid needs a native short side of 512; present needs valid and peak ≥ 30. The verdict is
//        "real" when present, "absent" when valid without the peak, "invalid" below 512.
//

public struct Capture: StackMember {
    public let name = "capture"

    public init() {}

    public func score(_ s: DetectionSignals) throws -> MemberOutput? {
        let c = s.capture().signature
        return MemberOutput(name: name, p: nil, verdict: c.valid && c.present ? "real" : (c.valid ? "absent" : "invalid"),
                            fields: [Field("peak", .number(c.peak)), Field("valid", .flag(c.valid)),
                                     Field("native_px", .number(Float(c.nativePixels))), Field("present", .flag(c.present))])
    }
}
