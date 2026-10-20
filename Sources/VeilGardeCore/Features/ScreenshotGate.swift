//
//  ScreenshotGate.swift
//  VeilGardeCore
//  SPDX-License-Identifier: GPL-3.0-only
//
//  WHAT: The flat-UI gate: a screenshot is real but not a camera capture, so the camera-anchored
//        fusion false-positives on it. Three tells taken together (many zero-gradient pixels,
//        many perfectly flat 16-px blocks, one dominant colour) mark a synthetic render; the
//        router then sends the image to the screenshot head.
//  PIN:  The joint rule is gradZero ≥ 0.50 and flatStrict ≥ 0.30 and topColor ≥ 0.18, on the image
//        capped at 2048 px (capture_signature.py screenshot_gate; AI false-fire about 2%, only on
//        flat graphic art). The tells are computed in Lens/Capture.
//

public struct ScreenshotGate: Sendable, Equatable {
    public let isScreenshot: Bool
    public let gradZero: Float
    public let flatStrict: Float
    public let topColor: Float

    public init(isScreenshot: Bool, gradZero: Float, flatStrict: Float, topColor: Float) {
        self.isScreenshot = isScreenshot
        self.gradZero = gradZero
        self.flatStrict = flatStrict
        self.topColor = topColor
    }

    public static let cap = 2048
    public static let gradZeroThreshold: Float = 0.50
    public static let flatStrictThreshold: Float = 0.30
    public static let topColorThreshold: Float = 0.18
    public static let none = ScreenshotGate(isScreenshot: false, gradZero: 0, flatStrict: 0, topColor: 0)

    /// The joint rule.
    public static func decide(gradZero: Float, flatStrict: Float, topColor: Float) -> ScreenshotGate {
        ScreenshotGate(isScreenshot: gradZero >= gradZeroThreshold && flatStrict >= flatStrictThreshold && topColor >= topColorThreshold,
                       gradZero: gradZero, flatStrict: flatStrict, topColor: topColor)
    }
}
