import HomeVideoCore
import SwiftUI

/// The sound, split by where it happens: the Mic first (Clean or
/// Camcorder, and for Camcorder its Strength and the mic's own adjustments), then the tape
/// Track as a menu with its layers, then the Audio wear slider beside the audio Damage layers.
/// Self contained: it needs only the audio chain and a way to keep a group's open state, so
/// a stage UI can host it anywhere. With Tape off the Track, its layers, the wear and the
/// Damage are shown disabled, since the mic plays alone.
struct AudioSection: View {
    let audio: AudioChain
    let groupBinding: (String) -> Binding<Bool>

    /// The camcorder mic's parameters as the section names them, plainly. The layer keeps its
    /// own ids and names (sidecars, `--set`, `--list-layers`).
    static let micNames: [String: String] = [
        "level": "Motor noise (dBFS)",
        "whine": "Motor pitch (Hz)",
        "lift": "Auto gain pumping (dB)",
        "seed": "Seed",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: ChainSidebar.groupGap) {
            mic
            track
            wearAndDamage
        }
        .animation(.easeOut(duration: 0.15), value: audio.mic)
    }

    private var mic: some View {
        PresetRow(title: "Mic", isCustom: false) {
            Picker("Mic", selection: Binding(get: { audio.mic }, set: { audio.mic = $0 })) {
                ForEach(AudioMic.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } sub: {
            if audio.mic == .camcorder {
                VStack(alignment: .leading, spacing: ChainSidebar.rowGap) {
                    slider("Strength", value: audio.micStrength, range: AudioChain.strengthRange,
                           help: "100 is the camcorder mic as it is, 0 the clean mic") {
                        audio.setMicStrength($0.rounded())
                    }
                    LayerControls(parameters: audio.micLayer.parameters.map { p in
                        var p = p
                        p.name = Self.micNames[p.id] ?? p.name
                        return p
                    }, enabled: true) { audio.micLayer.setParameter($0, to: $1) }
                }
                .padding(.leading, 16)
                .transition(.opacity)
            }
        }
    }

    private var track: some View {
        VStack(alignment: .leading, spacing: ChainSidebar.groupGap) {
            VStack(alignment: .leading, spacing: 4) {
                MenuRow(title: "Track") {
                    Picker("Track", selection: Binding(get: { audio.track }, set: { audio.setTrack($0) })) {
                        ForEach(AudioTrack.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                if !audio.tapeIsOn {
                    Text("Tape is off, so the mic plays alone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(audio.layers.filter { $0 !== audio.micLayer }, id: \.id) { layer in
                LayerGroup(title: LayerTitle.display(layer.name), isOpen: groupBinding(layer.id),
                           isOn: Binding(get: { layer.enabled }, set: { layer.enabled = $0 }),
                           opens: !layer.parameters.isEmpty) {
                    LayerControls(parameters: layer.parameters, enabled: layer.enabled) {
                        layer.setParameter($0, to: $1)
                    }
                }
            }
        }
        .disabled(!audio.tapeIsOn)
    }

    /// The Audio wear beside the audio Damage layers: the slow wear and the events.
    private var wearAndDamage: some View {
        VStack(alignment: .leading, spacing: ChainSidebar.groupGap) {
            slider("Audio wear", value: audio.wear, range: AudioWear.range,
                   help: "0 is the track as it is, 100 a badly worn tape: muffled, hissy, wobbly") {
                audio.setWear($0.rounded())
            }
            .disabled(audio.track == .off)
            ForEach(audio.damage, id: \.id) { layer in
                LayerGroup(title: LayerTitle.display(layer.name), isOpen: groupBinding(layer.id),
                           isOn: Binding(get: { layer.enabled }, set: { layer.enabled = $0 }),
                           opens: !layer.parameters.isEmpty) {
                    LayerControls(parameters: layer.parameters, enabled: layer.enabled) {
                        layer.setParameter($0, to: $1)
                    }
                }
            }
        }
        .disabled(!audio.tapeIsOn)
    }

    /// A whole-number slider with its title and readout.
    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, help: String,
                        set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Int(value.rounded()))").font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: set), in: range)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(title)
        }
        .help(help)
    }
}
