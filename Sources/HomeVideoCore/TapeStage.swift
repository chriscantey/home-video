import Foundation
import Metal
import Observation

/// The Tape stage's switch. On by default: the round trip to tape. Off, the picture skips
/// `VHSLayers.all` entirely and the stage before the tape goes straight
/// on: a Film scan, the Telecine's transfer at the raster, the framed source onto the Display,
/// or with every stage off the source untouched. `--set tape.enabled=off` and
/// `-homevideoSet tape.enabled=off` reach it, and so does the short form `tape=off`.
///
/// A file names it only while it is off, so a file written with the tape on reads as the
/// default. An older file with Film's output Scan loads as Tape off
/// (`VHSLayers.foldLegacyFilmOutput`).
@MainActor
@Observable
public final class TapeStageLayer: Layer {
    public let id = "tape"
    public let name = "Tape"
    public var enabled = true {
        didSet { if enabled != oldValue { onSwitch?(enabled) } }
    }

    /// Told when the switch moves, so the sound follows it: `SignalChain.standard()` sets
    /// the audio chain's `tapeIsOn` here, and Tape off plays the mic alone.
    @ObservationIgnored public var onSwitch: ((Bool) -> Void)?

    public init() {}

    /// The switch alone: what the tape does is the VHS layers' business.
    public var parameters: [LayerParameter] { [] }
    public func setParameter(_ id: String, to value: ParameterValue) {}

    public func prepare(device: MTLDevice, library: MTLLibrary) throws {}

    /// Never a chain step. Copies, so the protocol's contract holds if one is ever listed.
    public func encode(commandBuffer: MTLCommandBuffer, in input: MTLTexture, out output: MTLTexture,
                       frame: FrameContext) {
        guard let b = commandBuffer.makeBlitCommandEncoder() else { return }
        b.copy(from: input, to: output)
        b.endEncoding()
    }
}
