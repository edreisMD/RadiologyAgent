import SwiftUI

enum Theme {
    static let bg = Color(white: 0.105)
    static let sidebar = Color(white: 0.085)
    static let panel = Color(white: 0.145)
    static let raised = Color(white: 0.18)
    static let line = Color.white.opacity(0.075)
    static let text = Color(white: 0.92)
    static let muted = Color(white: 0.57)
    static let accent = Color(white: 0.86)
    static let amber = Color(red: 0.85, green: 0.68, blue: 0.41)
}

struct FlatButton: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        ButtonFeedback(configuration: configuration, primary: primary)
    }
    private struct ButtonFeedback: View {
        let configuration: ButtonStyle.Configuration
        let primary: Bool
        @Environment(\.isEnabled) var enabled
        @State private var hovering = false
        var body: some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(primary ? Theme.bg : Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(primary ? Theme.accent.opacity(configuration.isPressed ? 0.7 : 1) : (hovering ? Color(white: 0.24) : Theme.raised), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(hovering && enabled ? 0.12 : 0)))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0; (enabled && $0 ? NSCursor.pointingHand : NSCursor.arrow).set() }
        }
    }
}
/// Shared pointer, hover, and pressed feedback for every custom clickable surface.
struct HoverButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Feedback(configuration: configuration) }
    private struct Feedback: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(Color.white.opacity(enabled && hovering ? 0.075 : 0), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(enabled && hovering ? 0.06 : 0)))
                .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .onHover { hovering = $0; (enabled && $0 ? NSCursor.pointingHand : NSCursor.arrow).set() }
        }
    }
}

struct ControlHover: ViewModifier {
    @State private var hovering = false
    @Environment(\.isEnabled) var enabled
    func body(content: Content) -> some View {
        content.background(Color.white.opacity(enabled && hovering ? 0.075 : 0), in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0; (enabled && $0 ? NSCursor.pointingHand : NSCursor.arrow).set() }
    }
}
struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)).frame(width: 29, height: 28).foregroundStyle(active ? Theme.accent : Theme.muted).background(active ? Theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5)) }
            .buttonStyle(HoverButton()).help(help).accessibilityLabel(help)
    }
}
struct StatusPill: View {
    let title: String
    var color = Theme.accent
    var body: some View { HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(title).font(.system(size: 10, weight: .medium)) }.foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.085), in: Capsule()) }
}
struct AgentMark: View {
    var size: CGFloat = 29
    var body: some View {
        Image(systemName: "viewfinder").font(.system(size: size * 0.58, weight: .medium)).foregroundStyle(Theme.accent)
            .frame(width: size, height: size).background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.26))
    }
}
struct Rule: View { var body: some View { Rectangle().fill(Theme.line).frame(height: 1) } }
