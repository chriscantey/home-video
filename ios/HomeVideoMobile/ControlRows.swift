import SwiftUI

// The phone's rows for the Mac sidebar's controls, built the same way: from each layer's own
// `parameters`, a `.float` a Slider with the Mac's readout, a `.bool` a Toggle, a `.choice` a
// Picker. Names are the Mac's (`LayerTitle`), so the two apps read as one product.

/// One parameter as a native Form row.
struct ParameterRow: View {
    let parameter: LayerParameter
    /// The layer's id, for the accessibility identifier `param-<layer>.<parameter>`.
    let layerID: String
    let set: (ParameterValue) -> Void

    var body: some View {
        let id = "param-\(layerID).\(parameter.id)"
        switch parameter.value {
        case .choice(let current):
            Picker(parameter.name, selection: Binding(get: { current }, set: { set(.choice($0)) })) {
                ForEach(parameter.options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(id)
        case .float(let v):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(parameter.name)
                    Spacer(minLength: 8)
                    Text(parameter.readout(v))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { v }, set: { set(.float(parameter.id == "seed" ? $0.rounded() : $0)) }),
                       in: parameter.range)
                    .accessibilityLabel(parameter.name)
                    .accessibilityValue(parameter.readout(v))
                    .accessibilityIdentifier(id)
            }
        case .bool(let b):
            Toggle(parameter.name, isOn: Binding(get: { b }, set: { set(.bool($0)) }))
                .accessibilityIdentifier(id)
        }
    }
}

/// A layer's parameters, each disabled while it has no effect or the layer is off.
struct ParameterRows: View {
    let parameters: [LayerParameter]
    let layerID: String
    var enabled = true
    let set: (String, ParameterValue) -> Void

    var body: some View {
        ForEach(parameters) { p in
            ParameterRow(parameter: p, layerID: layerID) { set(p.id, $0) }
                .disabled(!p.isActive || !enabled)
        }
    }
}

/// One layer as a disclosure row: its switch beside the title ("Always on" for a required layer),
/// its parameters inside. A layer with nothing to change is a plain row, as on the Mac.
struct LayerRow: View {
    /// The few things a row needs, so a picture layer and a sound layer share it.
    struct Item {
        var id: String
        var name: String
        var isRequired: Bool
        var enabled: Binding<Bool>
        var parameters: [LayerParameter]
        var setParameter: (String, ParameterValue) -> Void
    }

    let layer: Item
    /// False while the stage the layer belongs to is off or waits on another.
    var live = true
    @State private var open = false

    /// A picture layer, with the parameters the stage shows when it reworks them (Telecine's route).
    init(_ layer: any Layer, parameters: [LayerParameter]? = nil, live: Bool = true) {
        self.layer = Item(id: layer.id, name: layer.name, isRequired: layer.isRequired,
                          enabled: Binding(get: { layer.enabled }, set: { layer.enabled = $0 }),
                          parameters: parameters ?? layer.parameters,
                          setParameter: { layer.setParameter($0, to: $1) })
        self.live = live
    }

    /// A sound layer.
    init(_ layer: AudioLayer, live: Bool = true) {
        self.layer = Item(id: layer.id, name: layer.name, isRequired: layer.isRequired,
                          enabled: Binding(get: { layer.enabled }, set: { layer.enabled = $0 }),
                          parameters: layer.parameters,
                          setParameter: { layer.setParameter($0, to: $1) })
        self.live = live
    }

    var body: some View {
        let params = layer.parameters
        let parts = LayerTitle.parts(LayerTitle.display(layer.name))
        let title = VStack(alignment: .leading, spacing: 2) {
            Text(parts.name)
            if let detail = parts.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        // The Mac's LayerGroup in a Form: the chevron and title open the layer, the switch
        // beside them is its own control, and the values follow as rows of their own. A system
        // DisclosureGroup with a Toggle in its label leaves the tap between the two ambiguous.
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .opacity(params.isEmpty ? 0 : 1)
                    title
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(params.isEmpty)
            .accessibilityLabel(parts.name)
            .accessibilityValue(params.isEmpty ? "" : (open ? "Expanded" : "Collapsed"))
            .accessibilityHint(params.isEmpty ? "" : "Shows the layer's values")
            .accessibilityIdentifier("group-\(layer.id)")
            if layer.isRequired {
                Text("Always on").font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle(parts.name, isOn: layer.enabled)
                    .labelsHidden()
                    .accessibilityIdentifier("layer-\(layer.id)")
            }
        }
        if open && !params.isEmpty {
            ParameterRows(parameters: params, layerID: layer.id, enabled: layer.enabled.wrappedValue && live) {
                layer.setParameter($0, $1)
            }
            .padding(.leading, 24)
        }
    }
}

/// A caption row in a stage's section, the Mac's gray line of what the stage does.
struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
