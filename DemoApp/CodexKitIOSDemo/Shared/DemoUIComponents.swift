import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct DemoSectionCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

@available(iOS 17.0, macOS 14.0, *)
struct DemoActionTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var isProminent = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(isProminent ? .white : Color.accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isProminent ? .white : .primary)
                        .multilineTextAlignment(.leading)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isProminent ? .white.opacity(0.82) : .secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
            .padding(14)
            .background(backgroundShape)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }

    @ViewBuilder
    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isProminent ? Color.accentColor : Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isProminent ? Color.accentColor : Color.primary.opacity(0.06),
                        lineWidth: 1
                    )
            )
    }
}
