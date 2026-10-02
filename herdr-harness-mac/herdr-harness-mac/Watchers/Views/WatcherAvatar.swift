import SwiftUI

struct WatcherAvatar: View {
    static let characters = ["pip", "hoot", "mochi", "bolt", "sprout", "juno", "rook", "nimbus", "echo", "clove", "atlas", "wren", "lumen", "tally", "quill", "orbit", "kit", "remy", "moss", "ziggy"]
    static let instruments = ["gauge", "cog", "metronome", "hourglass", "beacon", "relay", "terminal", "valve"]
    var avatar: String
    var resting = false
    var working = false
    var attention = false
    var size: CGFloat = 82
    static func tone(_ avatar: String) -> Color {
        switch avatar {
        case "hoot", "lumen", "cog": Color(red: 0.89, green: 0.75, blue: 0.50)
        case "mochi", "remy", "metronome": Color(red: 0.88, green: 0.64, blue: 0.71)
        case "echo", "moss", "gauge": Color(red: 0.58, green: 0.79, blue: 0.71)
        case "rook", "tally", "terminal": Color(red: 0.50, green: 0.76, blue: 0.77)
        case "clove", "ziggy", "hourglass": Color(red: 0.89, green: 0.66, blue: 0.56)
        case "juno", "kit", "valve": Color(red: 0.79, green: 0.64, blue: 0.87)
        case "nimbus", "orbit", "beacon": Color(red: 0.59, green: 0.78, blue: 0.91)
        case "sprout", "wren": Color(red: 0.69, green: 0.80, blue: 0.58)
        default: HerdrTheme.accent
        }
    }
    var body: some View {
        let tone = Self.tone(avatar)
        let character = Self.characters.contains(avatar)
        let resolved = (character || Self.instruments.contains(avatar)) ? avatar : "gauge"
        Image("Watcher-\(resolved)-\(resting ? "resting" : "idle")")
            .resizable().scaledToFit().padding(size * 0.05).frame(width: size, height: size)
            .background {
                if character { Circle().fill(tone.opacity(0.15)) }
                else { RoundedRectangle(cornerRadius: size * 0.29).fill(tone.opacity(0.15)) }
            }
            .overlay {
                if character { Circle().strokeBorder(working ? Color.mint.opacity(0.8) : tone.opacity(0.22), lineWidth: working ? 2 : 1) }
                else { RoundedRectangle(cornerRadius: size * 0.29).strokeBorder(working ? Color.mint.opacity(0.8) : tone.opacity(0.22), lineWidth: working ? 2 : 1) }
            }
            .overlay(alignment: .topTrailing) {
                if attention || resting {
                    Text(attention ? "!" : "z").font(.system(size: size * 0.18, weight: .bold)).foregroundStyle(attention ? Color.pink : tone)
                        .frame(width: size * 0.25, height: size * 0.25).background(HerdrTheme.windowBackground, in: .circle)
                }
            }
            .accessibilityHidden(true)
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
                    Button { selection = id } label: { VStack(spacing: 6) { WatcherAvatar(avatar: id, size: 52); Text(id.capitalized).font(.caption) }.padding(6).background(selection == id ? HerdrTheme.selectedFill : .clear, in: .rect(cornerRadius: 10)) }.buttonStyle(.plain)
                }
            }
        }.padding(22).frame(width: 400)
    }
}
