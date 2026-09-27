import SwiftUI

/// A 390 x 844 pt screen with the rounded corners and bezel of a current iPhone.
struct PhoneFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black
            content
        }
        .frame(width: 390, height: 844)
        .clipShape(.rect(cornerRadius: 55, style: .continuous))
        .padding(10)
        .background(.black, in: .rect(cornerRadius: 65, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 65, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
    }
}
