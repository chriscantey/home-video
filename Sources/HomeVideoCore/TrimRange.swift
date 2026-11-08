import Foundation

/// The part of a clip that plays and exports, in seconds of the clip. It belongs to the clip, not to
/// the chain: the chain is the picture and is shared by every open clip, a trim is the clip's
/// own time, so it lives on `FrameSource` and in the clip's sidecar.
///
/// The ends are always ordered and inside `0...duration` once clamped, and the range is never
/// shorter than `minimumLength`, so a handle dragged onto the other one still leaves a frame
/// or two to play.
public struct TrimRange: Equatable, Sendable {
    public var inPoint: Double
    public var outPoint: Double

    /// The shortest range a trim keeps, in seconds (a few frames at any rate).
    public static let minimumLength = 0.1

    /// The ends as given, put in order. Use `clamped(to:)` once the clip's duration is known.
    public init(in inPoint: Double, out outPoint: Double) {
        let a = inPoint.isFinite ? inPoint : 0
        let b = outPoint.isFinite ? outPoint : 0
        self.inPoint = min(a, b)
        self.outPoint = max(a, b)
    }

    public var length: Double { outPoint - inPoint }

    /// Ordered, inside `0...duration`, and at least `minimumLength` long (or the whole clip when
    /// it is shorter than that).
    public func clamped(to duration: Double) -> TrimRange {
        let d = max(duration.isFinite ? duration : 0, 0)
        var a = min(max(inPoint, 0), d)
        var b = min(max(outPoint, 0), d)
        if a > b { swap(&a, &b) }
        let minimum = min(Self.minimumLength, d)
        if b - a < minimum {
            // Grow toward whichever side has room.
            b = min(a + minimum, d)
            a = b - minimum
        }
        return TrimRange(in: a, out: b)
    }

    /// True when the range is the whole clip, so it means no trim at all.
    public func isWhole(of duration: Double, tolerance: Double = 0.001) -> Bool {
        inPoint <= tolerance && outPoint >= duration - tolerance
    }

    /// `t` moved into the range.
    public func clamp(_ t: Double) -> Double { min(max(t, inPoint), outPoint) }

    public func contains(_ t: Double) -> Bool { t >= inPoint && t <= outPoint }

    /// A copy with the in point at `t`, the out point kept: an in point pushed onto the out
    /// point stops `minimumLength` before it.
    public func settingIn(_ t: Double, duration: Double) -> TrimRange {
        TrimRange(in: min(t, outPoint - Self.minimumLength), out: outPoint).clamped(to: duration)
    }

    /// A copy with the out point at `t`, the in point kept: an out point pushed onto the in
    /// point stops `minimumLength` after it.
    public func settingOut(_ t: Double, duration: Double) -> TrimRange {
        TrimRange(in: inPoint, out: max(t, inPoint + Self.minimumLength)).clamped(to: duration)
    }
}
