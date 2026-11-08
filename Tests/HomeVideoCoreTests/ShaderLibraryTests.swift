import Metal
import XCTest
@testable import HomeVideoCore

final class ShaderLibraryTests: XCTestCase {
    func testLibraryLoadsWithAllKernels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let (lib, origin) = try ShaderLibrary.make(device: device)
        print("HomeVideoCore shader library origin: \(origin.rawValue)")
        for name in ["framing", "preview_vertex", "preview_fragment"] {
            XCTAssertNotNil(lib.makeFunction(name: name), "missing function \(name)")
        }
    }
}
