import SwiftUI

struct MenuBarBrandMark: View {
    var size: CGFloat

    var body: some View {
        Image("MenuBarMark")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("ChatGPT Skin Studio")
    }
}
