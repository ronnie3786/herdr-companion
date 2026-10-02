import SwiftUI

struct WatcherAvatar: View {
    static let characters = ["pip", "hoot", "mochi", "bolt", "sprout", "juno", "rook", "nimbus", "echo", "clove", "atlas", "wren", "lumen", "tally", "quill", "orbit", "kit", "remy", "moss", "ziggy"]
    static let instruments = ["gauge", "cog", "metronome", "hourglass", "beacon", "relay", "terminal", "valve"]
    var avatar: String
    var resting = false
    var working = false
    var attention = false
    var size: CGFloat = 82
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    /// The prototype's palette middle tone (`PAL[...].m`) for each avatar.
    static func toneHex(_ avatar: String) -> UInt32 {
        switch avatar {
        case "hoot", "lumen", "cog": 0xE3BF7F
        case "mochi", "remy", "metronome": 0xE0A4B5
        case "bolt", "atlas": 0x95A9EC
        case "echo", "moss", "gauge": 0x93CAB4
        case "rook", "tally", "terminal": 0x7FC2C4
        case "clove", "ziggy", "hourglass": 0xE4A98F
        case "juno", "kit", "valve": 0xC9A2DE
        case "nimbus", "orbit", "beacon": 0x97C6E8
        case "sprout", "wren": 0xB0CB94
        default: 0xABA5F2
        }
    }
    static func tone(_ avatar: String) -> Color { WatchersStyle.hex(toneHex(avatar)) }

    var body: some View {
        let character = Self.characters.contains(avatar)
        let resolved = character || Self.instruments.contains(avatar) ? avatar : "gauge"
        let toneHex = Self.toneHex(resolved)
        // An opaque face, `color-mix(tone 15%, #211E28)`, so the dusk never shows through the drawing.
        ZStack {
            WatchersStyle.mix(toneHex, 0.15, over: 0x211E28)
            Image("Watcher-\(resolved)-\(resting ? "resting" : "idle")").resizable().scaledToFit()
        }
        .frame(width: size, height: size)
        .clipShape(face(character))
        .overlay { faceOutline(character, color: WatchersStyle.hex(toneHex, 0.16)) }
        .saturation(resting ? 0.35 : 1)
        .colorMultiply(Color(white: resting ? 0.8 : 1))
        .opacity(resting ? 0.75 : 1)
        .overlay {
            if working {
                ring(character)
                    .opacity(pulse ? 0.3 : 0.85)
                    .shadow(color: WatchersStyle.mint.opacity(0.6), radius: 5)
                    .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true } } }
            }
        }
        .overlay(alignment: .topTrailing) { if resting { restingBadge.offset(x: 3, y: -2) } }
        .overlay(alignment: attention && resting ? .topLeading : .topTrailing) {
            if attention { flag.offset(x: resting ? -2 : 2, y: -2) }
        }
        .accessibilityHidden(true)
    }
    private func face(_ character: Bool) -> AnyShape {
        character ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
    @ViewBuilder private func faceOutline(_ character: Bool, color: Color) -> some View {
        if character { Circle().strokeBorder(color, lineWidth: 1) }
        else { RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(color, lineWidth: 1) }
    }
    /// A mint ring 4pt outside the face while a run is working.
    @ViewBuilder private func ring(_ character: Bool) -> some View {
        if character { Circle().inset(by: -4).stroke(WatchersStyle.mint, lineWidth: 1.5) }
        else { RoundedRectangle(cornerRadius: (size + 8) * 0.3, style: .continuous).inset(by: -4).stroke(WatchersStyle.mint, lineWidth: 1.5) }
    }
    private var restingBadge: some View {
        let badge = max(15, size * 0.3)
        return Text("z").font(.system(size: max(9, size * 0.15), weight: .semibold)).foregroundStyle(WatchersStyle.hex(0xC9C3DA))
            .frame(width: badge, height: badge)
            .background(WatchersStyle.hex(0x2A2536), in: .circle)
            .overlay(Circle().strokeBorder(HerdrTheme.outline, lineWidth: 1))
    }
    private var flag: some View {
        let badge = max(14, size * 0.27)
        return Text("!").font(.system(size: max(9, size * 0.16), weight: .heavy)).foregroundStyle(WatchersStyle.hex(0x2A1520))
            .frame(width: badge, height: badge)
            .background(WatchersStyle.rose, in: .circle)
            .background(WatchersStyle.hex(0x1B1820), in: Circle().inset(by: -2))
    }
}
struct WatcherAvatarPicker: View {
    var character: Bool
    @Binding var selection: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(character ? "Characters" : "Instruments").font(.headline)
            Text(character ? "A face means an agent thinks during the run." : "An instrument means scripts do the work.").font(.caption).foregroundStyle(HerdrTheme.secondaryText)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 16) {
                ForEach(character ? WatcherAvatar.characters : WatcherAvatar.instruments, id: \.self) { id in
                    Button { selection = id } label: { VStack(spacing: 6) { WatcherAvatar(avatar: id, size: 52); Text(id.capitalized).font(.caption) }.padding(6).background(selection == id ? HerdrTheme.selectedFill : .clear, in: .rect(cornerRadius: 10)) }.buttonStyle(.herdrPlain)
                }
            }
        }.padding(22).frame(width: 400)
    }
}
