import SwiftUI

/// The default panel under the picture: the Look carousel, Framing, and the way into every
/// control. The simple choices first, every other option one tap away.
/// The camera shows the same panel on its side, where the camera is the clip.
struct SimplePanel: View {
    let model: MobileModel
    /// Shuffle needs a picture to show: a clip in the editor, the live feed on the camera.
    var canShuffle: Bool? = nil
    /// Which carousel this is, for the stills that follow the cards on screen.
    var carousel = LookStills.editor
    /// Shows the All Controls button at the foot when set. The editor upright has its button in
    /// the bar instead.
    let showAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                LookHeader(model: model, canShuffle: canShuffle ?? (model.source != nil))
                LookCarousel(model: model, carousel: carousel)
                Text(model.look?.blurb ?? "Custom: a picker or slider has moved off every Look.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
            }
            FramingControls(framing: model.chain.framing)
                .padding(.horizontal)
            if let showAll {
                Button(action: showAll) {
                    Label("All Controls", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.horizontal)
                .accessibilityHint("Every stage and layer, as on the Mac")
                .accessibilityIdentifier("allControls")
            }
        }
        .padding(.vertical, 12)
    }
}

/// The Look's header row over the carousel: its name and Shuffle, in the editor and on the camera.
struct LookHeader: View {
    let model: MobileModel
    let canShuffle: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Look").font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(model.look?.name ?? "Custom")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("currentLook")
            Spacer()
            Button("Shuffle", systemImage: "dice") { model.shuffle() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .disabled(!canShuffle)
                .accessibilityIdentifier("shuffle")
        }
        .padding(.horizontal)
    }
}

/// Every Look as a card in one scrolling row, in the Mac's menu order: the clip's frame through
/// that Look (a placeholder until it is drawn), and its name. The chosen one is ringed.
struct LookCarousel: View {
    let model: MobileModel
    let carousel: String
    @ScaledMetric(relativeTo: .caption) private var baseWidth: CGFloat = 112
    /// The row's width from the leading margin to the safe area's edge.
    @State private var rowWidth: CGFloat = 0
    static let spacing: CGFloat = 10

    var body: some View {
        let current = model.look?.id
        let cardWidth = Self.cardWidth(base: baseWidth, row: rowWidth)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Not lazy: 29 small cards, and every one stays reachable for VoiceOver and tests.
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(Looks.grouped, id: \.category) { section in
                        ForEach(section.looks) { look in
                            LookCard(look: look, still: model.stills.images[look.id], chosen: look.id == current,
                                     width: cardWidth) {
                                model.choose(look)
                            }
                            .id(look.id)
                            .onScrollVisibilityChange(threshold: 0.01) { shown in
                                model.stills.setShown(look.id, shown, in: carousel)
                            }
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .insideMargins()
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            .onChange(of: current) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .accessibilityIdentifier("looks")
    }

    /// The part of the next card, as a share of a card, that should show past the last whole
    /// one, and the least that still reads as a card under the fade.
    static let peek: CGFloat = 0.4
    static let leastShown: CGFloat = 36

    /// The card width: the base, unless the row would end in the gap between two cards or on a
    /// card's first few points, where nothing says more is there (the iPhone Duo upright shows
    /// exactly three cards). Then the cards change size a little, the whole count nearest the
    /// base, so `peek` of the next card shows under the fade.
    static func cardWidth(base: CGFloat, row: CGFloat) -> CGFloat {
        let pitch = base + spacing
        guard row > pitch else { return base }
        let shown = row.truncatingRemainder(dividingBy: pitch)
        guard shown < leastShown || shown > base - 4 else { return base }
        let whole = (row / pitch).rounded(.down)
        let options = [whole - 1, whole, whole + 1].filter { $0 >= 1 }
            .map { k in (row - spacing * k) / (k + peek) }
        return options.min { abs($0 - base) < abs($1 - base) } ?? base
    }
}

struct LookCard: View {
    let look: Look
    let still: UIImage?
    let chosen: Bool
    let width: CGFloat
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if let still {
                        Image(uiImage: still)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    } else {
                        Rectangle().fill(.quaternary)
                        Image(systemName: LookCard.glyph(look.category))
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: width, height: width * 3 / 4)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        // `.tint`, not `Color.accentColor`, which the camera's full screen cover
                        // reads as the system blue.
                        .strokeBorder(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.12)),
                                      lineWidth: chosen ? 3 : 1)
                }
                Text(look.name)
                    .font(.caption.weight(chosen ? .semibold : .regular))
                    .foregroundStyle(chosen ? Color.primary : Color.secondary)
                    .lineLimit(2)
                    .frame(width: width, alignment: .leading)
            }
            .animation(.easeOut(duration: 0.2), value: still == nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(look.name)
        .accessibilityHint(look.blurb)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("look-\(look.id)")
    }

    /// A placeholder glyph per Look section, the Mac's stage glyphs.
    static func glyph(_ c: LookCategory) -> String {
        switch c {
        case .tape: "recordingtape"
        case .film: "film"
        case .telecine: "videoprojector"
        case .display: "tv"
        case .custom: "slider.horizontal.3"
        }
    }
}

/// Framing on the Simple panel: the Mode and Rotation menus, then Zoom and the two pans, each
/// dimmed when the mode does not move the window. The picture takes pinch and drag too.
struct FramingControls: View {
    let framing: FramingLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Framing").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !framing.isCropAtDefault {
                    Button("Reset Framing", systemImage: "arrow.counterclockwise") { framing.resetCrop() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("resetFraming")
                }
            }
            let params = framing.parameters
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { menus(params) }
                VStack(alignment: .leading, spacing: 10) { menus(params) }
            }
            ForEach(params.filter { $0.value.doubleValue != nil }) { p in
                ParameterRow(parameter: p, layerID: framing.id) { framing.setParameter(p.id, to: $0) }
                    .disabled(!p.isActive)
            }
        }
    }

    /// Mode and Rotation as glass menu buttons that show their choice.
    @ViewBuilder private func menus(_ params: [LayerParameter]) -> some View {
        ForEach(params.filter { $0.value.choiceValue != nil }) { p in
            let current = p.value.choiceValue ?? ""
            Menu {
                Picker(p.name, selection: Binding(get: { current }, set: { framing.setParameter(p.id, to: .choice($0)) })) {
                    ForEach(p.options, id: \.value) { Text($0.label).tag($0.value) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(p.name).foregroundStyle(.secondary)
                    Text(p.options.first { $0.value == current }?.label ?? current)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.glass)
            .tint(.primary)
            .accessibilityLabel(p.name)
            .accessibilityValue(p.options.first { $0.value == current }?.label ?? current)
            .accessibilityIdentifier("param-framing.\(p.id)")
        }
    }
}
