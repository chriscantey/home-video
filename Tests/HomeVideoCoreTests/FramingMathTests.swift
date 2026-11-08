import CoreGraphics
import XCTest
@testable import HomeVideoCore

final class FramingMathTests: XCTestCase {
    let hd = CGSize(width: 1920, height: 1080)
    let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    let eps: CGFloat = 1e-9

    func assertRect(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: eps, "x", file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: eps, "y", file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: eps, "w", file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: eps, "h", file: file, line: line)
    }

    func testLetterbox16x9FillsWidthWithBarsTopAndBottom() {
        let r = FramingMath.rects(sourceSize: hd, mode: .letterbox)
        assertRect(r.source, full)
        // (4/3) / (16/9) = 0.75 of the raster height, centered.
        assertRect(r.destination, CGRect(x: 0, y: 0.125, width: 1, height: 0.75))
        // On a 480 line raster that is 360 picture lines and 60 black lines above and below.
        XCTAssertEqual(r.destination.height * 480, 360, accuracy: eps)
    }

    func testLetterboxNarrowSourceIsPillarboxed() {
        let r = FramingMath.rects(sourceSize: CGSize(width: 1080, height: 1080), mode: .letterbox)
        assertRect(r.source, full)
        assertRect(r.destination, CGRect(x: 0.125, y: 0, width: 0.75, height: 1))
    }

    func testCropCenter16x9PanCenterLeftRight() {
        let c = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: 0)
        assertRect(c.source, CGRect(x: 0.125, y: 0, width: 0.75, height: 1))
        assertRect(c.destination, full)
        let l = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: -1)
        assertRect(l.source, CGRect(x: 0, y: 0, width: 0.75, height: 1))
        let r = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: 1)
        assertRect(r.source, CGRect(x: 0.25, y: 0, width: 0.75, height: 1))
        let half = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: 0.5)
        assertRect(half.source, CGRect(x: 0.1875, y: 0, width: 0.75, height: 1))
    }

    func testCropPanIsClamped() {
        let far = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: 7)
        assertRect(far.source, CGRect(x: 0.25, y: 0, width: 0.75, height: 1))
        let nan = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: .nan)
        assertRect(nan.source, CGRect(x: 0.125, y: 0, width: 0.75, height: 1))
    }

    func testCropCenterNarrowSourceCropsVerticallyAndPansUpAndDown() {
        let portrait = CGSize(width: 1080, height: 1920)
        // aspect 0.5625 / (4/3) = 0.421875 of the height. Pan 0 is centered.
        let h: CGFloat = 0.421875
        let c = FramingMath.rects(sourceSize: portrait, mode: .cropCenter, pan: 0)
        assertRect(c.source, CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h))
        assertRect(c.destination, full)
        // Pan -1 is the top of the picture, 1 the bottom, and the window never leaves it.
        let top = FramingMath.rects(sourceSize: portrait, mode: .cropCenter, pan: -1)
        assertRect(top.source, CGRect(x: 0, y: 0, width: 1, height: h))
        let bottom = FramingMath.rects(sourceSize: portrait, mode: .cropCenter, pan: 1)
        assertRect(bottom.source, CGRect(x: 0, y: 1 - h, width: 1, height: h))
        XCTAssertEqual(bottom.source.maxY, 1, accuracy: eps)
        let far = FramingMath.rects(sourceSize: portrait, mode: .cropCenter, pan: 9)
        assertRect(far.source, bottom.source)
    }

    func testFullRasterIsWholePictureWholeRaster() {
        for size in [hd, CGSize(width: 640, height: 480), CGSize(width: 1080, height: 1920)] {
            let r = FramingMath.rects(sourceSize: size, mode: .fullRaster, pan: 0.7)
            assertRect(r.source, full)
            assertRect(r.destination, full)
        }
    }

    func testFourByThreeSourceIsIdentityInEveryMode() {
        let size = CGSize(width: 640, height: 480)
        for mode in FramingMode.allCases {
            let r = FramingMath.rects(sourceSize: size, mode: mode, pan: -1)
            assertRect(r.source, full)
            assertRect(r.destination, full)
        }
    }

    func testDegenerateSizeDoesNotProduceNaN() {
        for size in [CGSize.zero, CGSize(width: 100, height: 0), CGSize(width: -5, height: 10)] {
            for mode in FramingMode.allCases {
                let r = FramingMath.rects(sourceSize: size, mode: mode, pan: 0)
                assertRect(r.source, full)
                assertRect(r.destination, full)
            }
        }
    }

    func assertInside(_ r: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(r.minX, -eps, file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.minY, -eps, file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxX, 1 + eps, file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxY, 1 + eps, file: file, line: line)
    }

    func testZoomOneIsTheCropAxisForm() {
        for size in [hd, CGSize(width: 1080, height: 1920), CGSize(width: 640, height: 480)] {
            for mode in FramingMode.allCases {
                for p: CGFloat in [-1, -0.4, 0, 0.7, 1] {
                    let old = FramingMath.rects(sourceSize: size, mode: mode, pan: p)
                    let wide = size.width / size.height >= FramingMath.rasterDisplayAspect
                    let new = FramingMath.rects(sourceSize: size, mode: mode, pan: wide ? p : 0,
                                                panY: wide ? 0 : p, zoom: 1)
                    assertRect(new.source, old.source)
                    assertRect(new.destination, old.destination)
                }
            }
        }
    }

    func testZoom2On16x9PansBothWaysInsideThePicture() {
        // Zoom 2 halves the 0.75 by 1 window to 0.375 by 0.5.
        let c = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: 0, panY: 0, zoom: 2)
        assertRect(c.source, CGRect(x: 0.3125, y: 0.25, width: 0.375, height: 0.5))
        assertRect(c.destination, full)
        let tl = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: -1, panY: -1, zoom: 2)
        assertRect(tl.source, CGRect(x: 0, y: 0, width: 0.375, height: 0.5))
        let br = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: 1, panY: 1, zoom: 2)
        assertRect(br.source, CGRect(x: 0.625, y: 0.5, width: 0.375, height: 0.5))
        XCTAssertEqual(br.source.maxX, 1, accuracy: eps)
        XCTAssertEqual(br.source.maxY, 1, accuracy: eps)
        for z: CGFloat in [1, 1.3, 1.5, 2] {
            for p: CGFloat in [-1, -0.5, 0, 0.5, 1] {
                for q: CGFloat in [-1, 0.25, 1] {
                    let r = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: p, panY: q, zoom: z)
                    assertInside(r.source)
                    // The window keeps the raster's 4:3 shape in display pixels.
                    XCTAssertEqual(r.source.width * hd.width / (r.source.height * hd.height), 4.0 / 3.0,
                                   accuracy: 1e-9)
                }
            }
        }
    }

    func testPortraitAtZoomOnePansOnlyVertically() {
        let portrait = CGSize(width: 1080, height: 1920)
        let h: CGFloat = 0.421875
        let base = FramingMath.rects(sourceSize: portrait, mode: .cropCenter, pan: 0, panY: 0, zoom: 1)
        let sideways = FramingMath.rects(sourceSize: portrait, mode: .cropCenter, pan: 1, panY: 0, zoom: 1)
        assertRect(sideways.source, base.source)
        let down = FramingMath.rects(sourceSize: portrait, mode: .cropCenter, pan: -1, panY: 1, zoom: 1)
        assertRect(down.source, CGRect(x: 0, y: 1 - h, width: 1, height: h))
        // Zoomed, the portrait window gains the horizontal axis.
        let zoomed = FramingMath.rects(sourceSize: portrait, mode: .cropCenter, pan: 1, panY: -1, zoom: 2)
        assertRect(zoomed.source, CGRect(x: 0.5, y: 0, width: 0.5, height: h / 2))
    }

    func testPanAndZoomAreClamped() {
        let far = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: 5, panY: -9, zoom: 7)
        assertRect(far.source, CGRect(x: 0.625, y: 0, width: 0.375, height: 0.5))
        let low = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: .nan, panY: .infinity, zoom: 0.2)
        assertRect(low.source, CGRect(x: 0.125, y: 0, width: 0.75, height: 1))
        let nanZoom = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: 0, panY: 0, zoom: .nan)
        assertRect(nanZoom.source, CGRect(x: 0.125, y: 0, width: 0.75, height: 1))
    }

    /// Stretch ignores Zoom and Pan. Fit inside ignores the pans at zoom 1, the whole
    /// picture with its bars, and above 1 grows the fitted picture: the bars shrink, and the pans
    /// move the window along an axis that has filled.
    func testZoomMovesFitInsideAndTheCropNeverStretch() {
        let a = FramingMath.rects(sourceSize: hd, mode: .fullRaster, pan: 0)
        XCTAssertEqual(a, FramingMath.rects(sourceSize: hd, mode: .fullRaster, pan: 1, panY: 1, zoom: 2))
        let fit = FramingMath.rects(sourceSize: hd, mode: .letterbox, pan: 0)
        XCTAssertEqual(fit, FramingMath.rects(sourceSize: hd, mode: .letterbox, pan: 1, panY: -1, zoom: 1),
                       "zoom 1: the pans do nothing")
        // 16:9 in 4:3 at zoom 1.2: the picture is 1.2 wide and 0.9 tall, so 1 / 1.2 of its width
        // shows across the canvas and the bars are 0.05 each.
        let z = FramingMath.rects(sourceSize: hd, mode: .letterbox, pan: 0, panY: 0, zoom: 1.2)
        assertRect(z.destination, CGRect(x: 0, y: 0.05, width: 1, height: 0.9))
        assertRect(z.source, CGRect(x: (1 - 1 / 1.2) / 2, y: 0, width: 1 / 1.2, height: 1))
        let right = FramingMath.rects(sourceSize: hd, mode: .letterbox, pan: 1, panY: 1, zoom: 1.2)
        assertRect(right.source, CGRect(x: 1 - 1 / 1.2, y: 0, width: 1 / 1.2, height: 1))
        // At zoom 2 the picture is 1.5 tall: no bars, the window 2 / 3 of its height, Pan Y moves it.
        let two = FramingMath.rects(sourceSize: hd, mode: .letterbox, pan: 0, panY: -1, zoom: 2)
        assertRect(two.destination, full)
        assertRect(two.source, CGRect(x: 0.25, y: 0, width: 0.5, height: 2.0 / 3))
        // A portrait clip on a canvas of its own shape (Fill at Match source): Fit inside and
        // Crop to fill are the same window at every zoom and pan.
        let tall = CGSize(width: 1080, height: 1920)
        for (zoom, pan, panY) in [(1.0, 0.0, 0.0), (1.6, 0.3, -0.7), (2.0, -1.0, 1.0)] {
            let f = FramingMath.rects(sourceSize: tall, mode: .letterbox, pan: pan, panY: panY, zoom: zoom,
                                      rasterAspect: 9.0 / 16)
            let c = FramingMath.rects(sourceSize: tall, mode: .cropCenter, pan: pan, panY: panY, zoom: zoom,
                                      rasterAspect: 9.0 / 16)
            assertRect(f.source, c.source)
            assertRect(f.destination, c.destination)
        }
    }

    /// Fit inside at zoom 1 is the plain fitted rects to the bit, whatever the pans say, so a
    /// render at zoom 1 is byte identical.
    func testFitInsideAtZoom1IsThePlainFit() {
        for size in [hd, CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080),
                     CGSize(width: 640, height: 480), CGSize(width: 3000, height: 1000)] {
            for aspect: CGFloat in [FramingMath.rasterDisplayAspect, 16.0 / 9, 9.0 / 16, 2] {
                let a = size.width / size.height
                let old = a >= aspect
                    ? FramingRects(source: full, destination: CGRect(x: 0, y: (1 - aspect / a) / 2, width: 1, height: aspect / a))
                    : FramingRects(source: full, destination: CGRect(x: (1 - a / aspect) / 2, y: 0, width: a / aspect, height: 1))
                for (pan, panY) in [(0.0, 0.0), (1.0, -1.0), (-0.4, 0.8)] {
                    let r = FramingMath.rects(sourceSize: size, mode: .letterbox, pan: pan, panY: panY, zoom: 1,
                                              rasterAspect: aspect)
                    XCTAssertEqual(r, old, "\(size) at \(aspect), pan \(pan) \(panY)")
                }
            }
        }
    }

    func testDragMovesThePictureWithTheCursor() {
        let crop = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: 0, panY: 0, zoom: 2).source
        // A drag a quarter of the view to the right moves the window left by a quarter of its
        // own width: 0.375 / 4 = 0.09375 of the picture, in pan units 2 * 0.09375 / 0.625 = 0.3.
        let d = FramingMath.panDelta(drag: CGVector(dx: 0.25, dy: 0), crop: crop)
        XCTAssertEqual(d.dx, -0.3, accuracy: eps)
        XCTAssertEqual(d.dy, 0, accuracy: eps)
        let moved = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: d.dx, panY: 0, zoom: 2).source
        XCTAssertEqual(crop.minX - moved.minX, 0.375 / 4, accuracy: eps)
        // Up a half view at zoom 2: the window moves down by half its height.
        let up = FramingMath.panDelta(drag: CGVector(dx: 0, dy: -0.5), crop: crop)
        XCTAssertEqual(up.dy, 2 * 0.5 * 0.5 / 0.5, accuracy: eps)
        // No room on an axis means no change there (16:9 at zoom 1 has no vertical room).
        let unzoomed = FramingMath.rects(sourceSize: hd, mode: .cropCenter, pan: 0).source
        XCTAssertEqual(FramingMath.panDelta(drag: CGVector(dx: 0.1, dy: 0.4), crop: unzoomed).dy, 0)
    }

    @MainActor
    func testZoomAndPanYGoThroughRenderSet() throws {
        let chain = SignalChain.standard()
        let a = try RenderArguments.parse(["in.mov", "out.mov", "--set", "framing.mode=cropCenter",
                                           "--set", "framing.zoom=1.5", "--set", "framing.panY=0.3",
                                           "--set", "framing.pan=-0.25"])
        try a.apply(to: chain)
        XCTAssertEqual(chain.framing.zoom, 1.5)
        XCTAssertEqual(chain.framing.panY, 0.3)
        XCTAssertEqual(chain.framing.pan, -0.25)
        XCTAssertFalse(chain.framing.isCropAtDefault)
        chain.framing.setParameter("zoom", to: .float(3))
        chain.framing.setParameter("panY", to: .float(-4))
        XCTAssertEqual(chain.framing.zoom, 2)
        XCTAssertEqual(chain.framing.panY, -1)
        chain.framing.resetCrop()
        XCTAssertTrue(chain.framing.isCropAtDefault)
        let ids = chain.framing.parameters.map(\.id)
        XCTAssertEqual(ids, ["mode", "zoom", "pan", "panY", "rotation"])
    }

    func testFitLetterboxesFourByThreeInsideWideView() {
        let r = FramingMath.fit(aspect: 4.0 / 3.0, in: CGSize(width: 1600, height: 900))
        assertRect(r, CGRect(x: 200, y: 0, width: 1200, height: 900))
        let tall = FramingMath.fit(aspect: 4.0 / 3.0, in: CGSize(width: 800, height: 900))
        assertRect(tall, CGRect(x: 0, y: 150, width: 800, height: 600))
    }
}
