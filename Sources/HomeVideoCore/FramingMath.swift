import CoreGraphics

/// How the source picture is placed on the 4:3 NTSC raster.
public enum FramingMode: String, CaseIterable, Sendable, Identifiable {
    /// The whole picture fitted inside 4:3 with black bars (letterbox for wide sources,
    /// pillarbox for narrow ones).
    case letterbox
    /// A 4:3 window cut from the center of the picture, panned by `pan` along the axis with
    /// room to move (sideways on a wide source, up and down on a portrait one).
    case cropCenter
    /// The whole picture squeezed to fill the raster (anamorphic for 16:9 sources).
    case fullRaster

    /// True when Zoom and Pan move the picture: Fit inside as well as Crop to fill, in every
    /// Picture mode. Stretch always shows the whole picture.
    public var movesWindow: Bool { self != .fullRaster }

    public var id: String { rawValue }

    /// Each name says what the mode does. The raw values stay, so files keep working.
    public var label: String {
        switch self {
        case .letterbox: return "Fit inside"
        case .cropCenter: return "Crop to fill"
        case .fullRaster: return "Stretch"
        }
    }
}

/// Normalized rects (0...1, origin top left) for the framing pass.
public struct FramingRects: Equatable, Sendable {
    /// Region of the source picture that is sampled.
    public var source: CGRect
    /// Region of the raster the sampled picture fills. Outside it is black.
    public var destination: CGRect

    public init(source: CGRect, destination: CGRect) {
        self.source = source
        self.destination = destination
    }
}

public enum FramingMath {
    /// Display aspect of the NTSC raster. 720 by 480 with 10:11 pixels is shown as 4:3;
    /// the 8 extra pixels of horizontal blanking width are treated as picture here.
    public static let rasterDisplayAspect: CGFloat = 4.0 / 3.0

    /// Zoom range of the center crop and Fit inside: 1 is the largest 4:3 window or the whole
    /// fitted picture, 2 is half its width and height.
    public static let zoomRange: ClosedRange<CGFloat> = 1...2

    /// Sample and destination rects for a source of `sourceSize` display pixels, at zoom 1.
    /// `pan` runs from -1 to 1 along the axis the crop can move: left to right on a source wider
    /// than the raster, top to bottom on one narrower (a portrait clip).
    /// A degenerate size (zero or negative) is treated as already 4:3.
    public static func rects(sourceSize: CGSize, mode: FramingMode, pan: CGFloat = 0,
                             rasterAspect: CGFloat = rasterDisplayAspect) -> FramingRects {
        let wide = sourceSize.height <= 0 || sourceSize.width / sourceSize.height >= rasterAspect
        return rects(sourceSize: sourceSize, mode: mode, pan: wide ? pan : 0, panY: wide ? 0 : pan,
                     zoom: 1, rasterAspect: rasterAspect)
    }

    /// Sample and destination rects with the center crop zoomed and panned on both axes.
    /// `zoom` (1 to 2) shrinks the crop window on both axes. `pan` (-1 left to 1 right) and
    /// `panY` (-1 top to 1 bottom) place it inside the picture, each along an axis with room.
    /// An axis with none stays centered. Zoom and pans move the center crop and Fit inside, never
    /// Stretch, and every value is clamped, so the window never leaves the picture.
    public static func rects(sourceSize: CGSize, mode: FramingMode, pan: CGFloat, panY: CGFloat,
                             zoom: CGFloat, rasterAspect: CGFloat = rasterDisplayAspect) -> FramingRects {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard sourceSize.width > 0, sourceSize.height > 0, rasterAspect > 0 else {
            return FramingRects(source: full, destination: full)
        }
        let aspect = sourceSize.width / sourceSize.height

        switch mode {
        case .fullRaster:
            return FramingRects(source: full, destination: full)

        case .letterbox:
            // The whole picture fitted (full width on a wide source, full height on a narrow
            // one), then grown about the center by the zoom: the part past the canvas is
            // cut, so the bars shrink, and the pans place the window along an axis that has
            // filled. At zoom 1 the window is the whole picture and nothing moves.
            let fw = aspect >= rasterAspect ? 1 : aspect / rasterAspect
            let fh = aspect >= rasterAspect ? rasterAspect / aspect : 1
            let z = clampZoom(zoom)
            let dw = min(1, fw * z), dh = min(1, fh * z)
            let sw = dw / (fw * z), sh = dh / (fh * z)
            let x = (1 - sw) * (clampPan(pan) + 1) / 2
            let y = (1 - sh) * (clampPan(panY) + 1) / 2
            return FramingRects(source: CGRect(x: x, y: y, width: sw, height: sh),
                                destination: CGRect(x: (1 - dw) / 2, y: (1 - dh) / 2, width: dw, height: dh))

        case .cropCenter:
            // The largest 4:3 window (full height on a wide source, full width on a portrait
            // phone clip), shrunk by the zoom, then placed by the pans.
            let z = clampZoom(zoom)
            let w = (aspect >= rasterAspect ? rasterAspect / aspect : 1) / z
            let h = (aspect >= rasterAspect ? 1 : aspect / rasterAspect) / z
            let x = (1 - w) * (clampPan(pan) + 1) / 2
            let y = (1 - h) * (clampPan(panY) + 1) / 2
            return FramingRects(source: CGRect(x: x, y: y, width: w, height: h), destination: full)
        }
    }

    public static func clampPan(_ p: CGFloat) -> CGFloat { min(max(p.isFinite ? p : 0, -1), 1) }

    public static func clampZoom(_ z: CGFloat) -> CGFloat {
        min(max(z.isFinite ? z : 1, zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// The pan change that makes the picture follow a drag under the center crop. `drag` is the
    /// cursor's travel as a fraction of the view (x right, y down), so a drag across the whole
    /// view moves the window by its own width (the view's width in source pixels). Moving the
    /// cursor right shows more of the left of the picture, so the pan goes down. An axis with
    /// no room returns 0.
    public static func panDelta(drag: CGVector, crop: CGRect) -> CGVector {
        func axis(_ d: CGFloat, _ size: CGFloat) -> CGFloat {
            let room = 1 - size
            guard room > 1e-9, d.isFinite else { return 0 }
            // x = room * (pan + 1) / 2, so a move of `d * size` in x is `2 * d * size / room` in pan.
            return -2 * d * size / room
        }
        return CGVector(dx: axis(drag.dx, crop.width), dy: axis(drag.dy, crop.height))
    }

    /// Clockwise rotation in degrees (0, 90, 180, 270) that a track's preferredTransform
    /// applies, rounded to the nearest quarter turn.
    public static func rotation(of t: CGAffineTransform) -> Int {
        let deg = atan2(Double(t.b), Double(t.a)) * 180 / .pi
        let q = Int((deg / 90).rounded())
        return ((q % 4) + 4) % 4 * 90
    }

    /// Clamps an arbitrary angle to 0, 90, 180 or 270.
    public static func normalizedRotation(_ degrees: Int) -> Int {
        ((Int((Double(degrees) / 90).rounded()) % 4) + 4) % 4 * 90
    }

    /// The source size as displayed: width and height swap for a quarter turn.
    public static func displaySize(_ size: CGSize, rotation: Int) -> CGSize {
        normalizedRotation(rotation) % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// Maps a normalized point of the displayed (rotated) picture to the normalized point of
    /// the decoded buffer, for a clockwise display rotation. The framing shader mirrors this.
    /// 90 is the iPhone portrait transform (a 0, b 1, c -1, d 0): display x runs down the
    /// buffer's y axis from the bottom, display y runs along the buffer's x axis.
    public static func bufferPoint(_ p: CGPoint, rotation: Int) -> CGPoint {
        switch normalizedRotation(rotation) {
        case 90: return CGPoint(x: p.y, y: 1 - p.x)
        case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 270: return CGPoint(x: 1 - p.y, y: p.x)
        default: return p
        }
    }

    /// The largest rect of `aspect` centered inside `bounds`, used to letterbox the 4:3
    /// preview inside an arbitrary view.
    public static func fit(aspect: CGFloat, in bounds: CGSize) -> CGRect {
        guard aspect > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        if bounds.width / bounds.height > aspect {
            let w = bounds.height * aspect
            return CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        } else {
            let h = bounds.width / aspect
            return CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        }
    }
}
