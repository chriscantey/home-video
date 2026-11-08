import CoreVideo
import Foundation
import Metal

/// The 8 bit pixel layout an export writes.
public enum ExportPixelFormat: String, CaseIterable, Sendable {
    /// 4:2:2 Y'CbCr, bytes Cb Y0 Cr Y1, video range (`kCVPixelFormatType_422YpCbCr8`).
    case yuv422 = "2vuy"
    /// 8 bit BGRA, full range; the writer converts to Y'CbCr from the buffer's tags.
    case bgra

    public var cvFormat: OSType {
        switch self {
        case .yuv422: return kCVPixelFormatType_422YpCbCr8
        case .bgra: return kCVPixelFormatType_32BGRA
        }
    }

    public var bytesPerPixel: Int {
        switch self {
        case .yuv422: return 2
        case .bgra: return 4
        }
    }

    var kernelName: String {
        switch self {
        case .yuv422: return "raster_to_2vuy"
        case .bgra: return "raster_to_bgra"
        }
    }
}

/// Luma coefficients of a Y'CbCr matrix.
public struct YCbCrMatrix: Equatable, Sendable {
    public var kr: Double
    public var kb: Double
    public var kg: Double { 1 - kr - kb }

    public init(kr: Double, kb: Double) {
        self.kr = kr
        self.kb = kb
    }

    /// ITU-R BT.601, the matrix the export tags (`kCVImageBufferYCbCrMatrix_ITU_R_601_4`).
    public static let bt601 = YCbCrMatrix(kr: 0.299, kb: 0.114)
    public static let bt709 = YCbCrMatrix(kr: 0.2126, kb: 0.0722)

    /// CPU reference of one pixel, video range 8 bit. Same rounding and clamp as the kernel,
    /// whose chroma for a pair is this function's chroma for the even pixel.
    public func encode(r: Double, g: Double, b: Double) -> (y: UInt8, cb: UInt8, cr: UInt8) {
        let r = min(max(r, 0), 1), g = min(max(g, 0), 1), b = min(max(b, 0), 1)
        let y = kr * r + kg * g + kb * b
        let cb = (b - y) / (2 * (1 - kb))
        let cr = (r - y) / (2 * (1 - kr))
        func code(_ v: Double) -> UInt8 { UInt8(min(max((v + 0.5).rounded(.down), 1), 254)) }
        return (code(16 + 219 * y), code(128 + 224 * cb), code(128 + 224 * cr))
    }
}

/// Packs the RGBA16Float working raster into an 8 bit buffer in an export pixel format,
/// with one compute pass into a shared `MTLBuffer` the CPU then copies into a pool buffer.
/// A plain buffer is used, not a texture over the pixel buffer, because Metal has no texture
/// format that writes raw 2vuy bytes through the texture cache without resampling.
@MainActor
public final class RasterConverter {
    public let format: ExportPixelFormat
    public let matrix: YCbCrMatrix
    public let width: Int
    public let height: Int
    public let buffer: MTLBuffer
    private let pipeline: MTLComputePipelineState

    public var bytesPerRow: Int { width * format.bytesPerPixel }

    public init(device: MTLDevice, library: MTLLibrary, format: ExportPixelFormat,
                matrix: YCbCrMatrix = .bt601,
                width: Int = SignalChain.rasterWidth, height: Int = SignalChain.rasterHeight) throws {
        guard let fn = library.makeFunction(name: format.kernelName) else {
            throw ShaderLibrary.LoadError.noLibrary("kernel '\(format.kernelName)'")
        }
        pipeline = try device.makeComputePipelineState(function: fn)
        guard let buf = device.makeBuffer(length: width * height * format.bytesPerPixel,
                                          options: .storageModeShared) else {
            throw ShaderLibrary.LoadError.noLibrary("could not allocate export buffer")
        }
        buf.label = "export \(format.rawValue)"
        buffer = buf
        self.format = format
        self.matrix = matrix
        self.width = width
        self.height = height
    }

    /// Encodes the conversion of `raster` into `buffer`. Read the buffer after the command
    /// buffer completes.
    public func encode(commandBuffer: MTLCommandBuffer, raster: MTLTexture) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "Convert \(format.rawValue)"
        enc.setComputePipelineState(pipeline)
        enc.setTexture(raster, index: 0)
        enc.setBuffer(buffer, offset: 0, index: 0)
        // Matches `ConvertParams` in Export.metal: two floats, two uints.
        var params: (Float, Float, UInt32, UInt32) = (Float(matrix.kr), Float(matrix.kb),
                                                     UInt32(width), UInt32(height))
        enc.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 1)
        let threadsWide = format == .yuv422 ? width / 2 : width
        dispatch2D(enc, pipeline: pipeline, width: threadsWide, height: height)
        enc.endEncoding()
    }

    /// Copies the converted bytes into `pixelBuffer`, row by row (its stride may be padded).
    public func copy(into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rows = min(height, CVPixelBufferGetHeight(pixelBuffer))
        let n = min(bytesPerRow, dstStride)
        let src = buffer.contents()
        for y in 0..<rows {
            memcpy(base + y * dstStride, src + y * bytesPerRow, n)
        }
    }
}
