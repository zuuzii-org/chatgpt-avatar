import SwiftUI

struct MenuBarBrandMark: View {
    var size: CGFloat

    var body: some View {
        Image("MenuBarMark")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.primary)
            .accessibilityLabel("ChatGPT Skin Studio")
    }
}
