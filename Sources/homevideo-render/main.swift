import Foundation
import HomeVideoCore

// homevideo-render: runs the Home Video Exporter headless. No window and no app bundle, so it works over
// ssh. See RenderArguments.usage.

func fail(_ message: String, code: Int32 = 1) -> Int32 {
    FileHandle.standardError.write(Data("homevideo-render: \(message)\n".utf8))
    return code
}

@MainActor
func describe(_ chain: SignalChain) -> String {
    chain.settingsLayers.map { layer in
        let params = layer.parameters.map { p -> String in
            switch p.value {
            case .float(let v): return "\(p.id)=\(v) (\(p.range.lowerBound)...\(p.range.upperBound))"
            case .bool(let b): return "\(p.id)=\(b)"
            case .choice(let c): return "\(p.id)=\(c) (\(p.options.map(\.value).joined(separator: "|")))"
            }
        }
        let state = layer.isRequired ? "required" : (layer.enabled ? "on" : "off")
        // The Damage pass's layers say so: set by the worn Looks, switched with --set <id>.enabled=on.
        let damage = layer is any DamageLayer ? " damage" : (layer is any CRTLayer ? " display" : "")
        return "\(layer.id) [\(state)\(damage)] \(params.joined(separator: ", "))"
    }.joined(separator: "\n") + "\naudio preset \(chain.audio.preset.rawValue) (hifi|camcorder|linearnr|linear|wornlinear|eplinear|off), "
        + "mic \(chain.audio.mic.rawValue) (clean|camcorder), track \(chain.audio.track.rawValue) (hifi|linearnr|linear|worn|ep|off), "
        + "mic strength \(chain.audio.micStrength), audio wear \(chain.audio.wear)\n"
        + chain.audio.allLayers.map { layer in
            let params = layer.parameters.map { p -> String in
                switch p.value {
                case .float(let v): return "\(p.id)=\(v) (\(p.range.lowerBound)...\(p.range.upperBound))"
                case .bool(let b): return "\(p.id)=\(b)"
                case .choice(let c): return "\(p.id)=\(c) (\(p.options.map(\.value).joined(separator: "|")))"
                }
            }
            let damage = AudioLayerKind.damage.contains(layer.kind) ? " damage" : ""
            return "\(layer.id) [\(layer.enabled ? "on" : "off")\(damage)] \(params.joined(separator: ", "))"
        }.joined(separator: "\n")
}

@MainActor
func run() async -> Int32 {
    let args: RenderArguments
    do {
        args = try RenderArguments.parse(Array(CommandLine.arguments.dropFirst()))
    } catch {
        return fail("\(error)\n\(RenderArguments.usage)", code: 64)
    }
    let chain = SignalChain.standard()
    if args.listLooks {
        for look in Looks.all { print("\(look.id)\t\(look.name)\t\(look.blurb)") }
    }
    if args.listLayers {
        if let look = args.look, let vhs = chain.vhs { Presets(vhs: vhs, audio: chain.audio).setLook(look) }
        print(describe(chain))
    }
    if (args.listLooks || args.listLayers) && args.input.isEmpty { return 0 }
    let applied: RenderArguments.Applied
    do {
        applied = try args.apply(to: chain)
    } catch {
        return fail("\(error)", code: 64)
    }
    let input = URL(fileURLWithPath: args.input)
    let output = URL(fileURLWithPath: args.output)
    guard FileManager.default.fileExists(atPath: input.path) else { return fail("no such file: \(args.input)") }
    guard input.standardizedFileURL != output.standardizedFileURL else {
        return fail("output would overwrite the input")
    }

    let exporter = Exporter(source: input, destination: output, chain: chain, maxFrames: args.frames,
                            pixelFormat: args.pixelFormat, settings: args.export)
    exporter.trim = applied.trim
    var lastReported = -1
    exporter.onProgress = { p in
        let pct = Int(p * 100)
        if pct / 10 != lastReported / 10 {
            lastReported = pct
            FileHandle.standardError.write(Data("homevideo-render: \(pct)%\n".utf8))
        }
    }
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { MainActor.assumeIsolated { exporter.cancel() } }
    sigint.resume()

    let start = Date()
    do {
        let r = try await exporter.run()
        let secs = Date().timeIntervalSince(start)
        let enabled = chain.layersInUse.map(\.id).joined(separator: ",")
        let audio = !r.audioPassedThrough ? "none" : (r.audioProcessed.map { "\($0.rawValue) (AAC)" } ?? "passthrough")
        print("homevideo-render: wrote \(r.framesWritten) frames to \(output.path) in \(String(format: "%.1f", secs)) s; "
              + "pixel format \(r.pixelFormat.rawValue), audio \(audio), "
              + "source rotation \(r.sourceRotationDegrees), layers \(enabled)"
              // Only when used, so a plain run's line reads as it always did.
              + (applied.trim.map { t in
                  "; range \(String(format: "%.3f", t.inPoint)) to "
                      + (t.outPoint >= Double.greatestFiniteMagnitude / 2 ? "the end" : String(format: "%.3f s", t.outPoint))
              } ?? "")
              + (applied.sidecar.map { "; sidecar \($0)" } ?? (args.clipSidecar ? "; sidecar none" : "")))
        return 0
    } catch {
        return fail("\(error)")
    }
}

// `--preview-check <clip>`: the app's preview path for 5 s in a small window, counters out. It
// runs here, on the main thread before dispatchMain(), because AppKit and the display link need
// the main run loop, which dispatchMain() never runs.
let previewArgs = Array(CommandLine.arguments.dropFirst())
if previewArgs.first == "--preview-check" {
    guard previewArgs.count == 2 else { exit(fail("usage: homevideo-render --preview-check <clip>", code: 64)) }
    print(MainActor.assumeIsolated { PreviewCheck.run(url: URL(fileURLWithPath: previewArgs[1])) }, terminator: "")
    exit(0)
}

Task { @MainActor in
    exit(await run())
}
dispatchMain()
