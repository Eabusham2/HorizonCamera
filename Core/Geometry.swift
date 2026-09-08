import Foundation

public struct Point2: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Point2(0, 0)
    public static func + (l: Point2, r: Point2) -> Point2 { Point2(l.x + r.x, l.y + r.y) }
    public static func - (l: Point2, r: Point2) -> Point2 { Point2(l.x - r.x, l.y - r.y) }
    public static func * (l: Point2, r: Double) -> Point2 { Point2(l.x * r, l.y * r) }
    public var length: Double { hypot(x, y) }
}

public struct Size2: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }
    public var center: Point2 { Point2(width / 2, height / 2) }
    public var isValid: Bool { width.isFinite && height.isFinite && width > 0 && height > 0 }
}

public enum GeometryError: Error { case invalidInput }

/// A single transform, shared by preview, export, touch mapping and tracking.
/// All coordinates use an UNMIRRORED-OR-EXPLICITLY-MIRRORED portrait source,
/// lower-left origin, and pixels (not UIKit's upper-left points).
public struct CropPlan: Sendable {
    public let source: Size2
    public let output: Size2
    public let angle: Double
    public let scale: Double
    public let center: Point2
    public let wasClamped: Bool
    public let halfFootprint: Point2
    public var sourceDetail: Size2 { Size2(output.width / scale, output.height / scale) }
    public var upscales: Bool { scale > 1.01 }

    public func sourceToOutput(_ p: Point2) -> Point2 {
        let d = p - center
        let c = cos(angle), s = sin(angle)
        return Point2((c * d.x - s * d.y) * scale + output.width / 2,
                      (s * d.x + c * d.y) * scale + output.height / 2)
    }
    public func outputToSource(_ p: Point2) -> Point2 {
        let d = (p - output.center) * (1 / scale)
        let c = cos(angle), s = sin(angle)
        return Point2(c * d.x + s * d.y, -s * d.x + c * d.y) + center
    }
    /// Keep a selected subject at its chosen on-screen position, NOT necessarily center.
    public func centerHolding(target: Point2, at normalizedAnchor: Point2) -> Point2 {
        let anchor = Point2(normalizedAnchor.x * output.width, normalizedAnchor.y * output.height)
        let offset = outputToSource(anchor) - center
        return target - offset
    }
}

public enum CropGeometry {
    /// Full-turn mode uses a constant inscribed-circle crop: no zoom pumping as
    /// the phone passes 45/90/180 degrees, and no black corners at any roll angle.
    public static func plan(source: Size2, output: Size2, angle: Double,
                            zoom: Double = 1, fullTurn: Bool,
                            reserve: Double = 1, requestedCenter: Point2? = nil) throws -> CropPlan {
        guard source.isValid, output.isValid, angle.isFinite, zoom.isFinite,
              zoom >= 1, reserve.isFinite, reserve > 0, reserve <= 1 else {
            throw GeometryError.invalidInput
        }
        let c = abs(cos(angle)), s = abs(sin(angle))
        let base: Double
        if fullTurn {
            base = hypot(output.width, output.height) / min(source.width, source.height)
        } else {
            base = max((c * output.width + s * output.height) / source.width,
                       (s * output.width + c * output.height) / source.height)
        }
        let scale = base * zoom / reserve
        let half = Point2((c * output.width + s * output.height) / (2 * scale),
                          (s * output.width + c * output.height) / (2 * scale))
        let desired = requestedCenter ?? source.center
        guard desired.x.isFinite, desired.y.isFinite else { throw GeometryError.invalidInput }
        let center = Point2(clamp(desired.x, half.x, source.width - half.x),
                            clamp(desired.y, half.y, source.height - half.y))
        return CropPlan(source: source, output: output, angle: angle, scale: scale,
                        center: center, wasClamped: (center - desired).length > 0.25,
                        halfFootprint: half)
    }
    public static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(value, lo), max(lo, hi))
    }
}
