import Foundation

/// A layer's title as the sidebar shows it. The "L1" to "L9" in front of some
/// layer names are our stage numbers from docs/SIGNAL-CHAIN.md, not tape terms, so the sidebar
/// drops them. `Layer.name` keeps them for the docs, the logs and the Metal labels. No file
/// stores a layer's name (sidecars, presets, the clipboard and the fingerprint use its id), so
/// stripping at display changes nothing on disk.
public enum LayerTitle {
    /// The name with a leading stage number ("L" and digits, then a space) removed.
    public static func display(_ name: String) -> String {
        guard let r = name.range(of: #"^L[0-9]+ +"#, options: .regularExpression) else { return name }
        return String(name[r.upperBound...])
    }

    /// True when a title still starts with a stage number.
    public static func hasStageNumber(_ title: String) -> Bool {
        title.range(of: #"^L[0-9]"#, options: .regularExpression) != nil
    }

    /// The displayed title as the name and its trailing parenthetical, which the sidebar draws
    /// as a smaller second line, so a long title is not cut off. "L3 Luma record (emphasis, clip,
    /// bandwidth)" gives
    /// "Luma record" and "emphasis, clip, bandwidth". A name with no trailing parenthetical has
    /// no detail.
    public static func parts(_ name: String) -> (name: String, detail: String?) {
        let title = display(name)
        guard title.hasSuffix(")"), let open = title.range(of: " (", options: .backwards) else {
            return (title, nil)
        }
        let head = String(title[..<open.lowerBound])
        let detail = String(title[open.upperBound..<title.index(before: title.endIndex)])
        guard !head.isEmpty, !detail.isEmpty else { return (title, nil) }
        return (head, detail)
    }

    /// False for a layer the sidebar leaves out because nobody can change it: a layer with no
    /// parameters that is locked on. The Output card is locked on whenever any layer between it
    /// and Capture runs, so it is left out in every state, or its row would come and go as those
    /// switches change. The layer stays in the chain, the render and the fingerprint. A required
    /// layer with parameters is listed, with its "Always on" tag.
    @MainActor
    public static func isListed(_ layer: any Layer) -> Bool {
        !(layer.parameters.isEmpty && (layer.isRequired || layer is OutputCardLayer))
    }
}
