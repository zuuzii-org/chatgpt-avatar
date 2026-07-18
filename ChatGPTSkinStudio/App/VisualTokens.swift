import SwiftUI

enum StudioVisualTokens {
    static let canvas = Color(red: 0.027, green: 0.043, blue: 0.071)
    static let panel = Color(red: 0.055, green: 0.086, blue: 0.137)
    static let elevated = Color(red: 0.075, green: 0.114, blue: 0.176)
    static let line = Color(red: 0.15, green: 0.21, blue: 0.29)
    static let text = Color(red: 0.957, green: 0.969, blue: 0.984)
    static let muted = Color(red: 0.61, green: 0.68, blue: 0.76)
    static let cyan = Color(red: 0.396, green: 0.847, blue: 0.91)
    static let purple = Color(red: 0.604, green: 0.486, blue: 1)
    static let green = Color(red: 0.333, green: 0.839, blue: 0.659)
    static let amber = Color(red: 0.957, green: 0.722, blue: 0.376)
    static let red = Color(red: 1, green: 0.42, blue: 0.47)
}

struct StudioCardModifier: ViewModifier {
    var accent: Color? = nil

    func body(content: Content) -> some View {
        content
            .background(StudioVisualTokens.panel.opacity(0.94))
            .overlay(alignment: .leading) {
                if let accent {
                    Rectangle()
                        .fill(accent)
                        .frame(width: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(StudioVisualTokens.line, lineWidth: 1)
            }
    }
}

extension View {
    func studioCard(accent: Color? = nil) -> some View {
        modifier(StudioCardModifier(accent: accent))
    }
}
