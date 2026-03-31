import SwiftUI

// MARK: - Dark Text Field

struct DarkTextFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: Theme.buttonRadius)
                    .fill(Theme.inputBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.buttonRadius)
                    .strokeBorder(Theme.borderColor, lineWidth: 1)
            )
            .foregroundStyle(Theme.primaryText)
            .font(Theme.captionFont)
    }
}

extension View {
    func darkTextField() -> some View {
        modifier(DarkTextFieldModifier())
    }
}

// MARK: - Dark Card

struct DarkCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .fill(Theme.cardBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.borderColor, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }
}

extension View {
    func darkCard() -> some View {
        modifier(DarkCardModifier())
    }
}

// MARK: - Dark Divider

struct DarkDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.borderColor)
            .frame(height: 0.5)
    }
}

// MARK: - Tab Selector

struct TabSelector<T: Hashable & CaseIterable & RawRepresentable>: View where T.RawValue == String, T.AllCases: RandomAccessCollection {
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 4) {
            ForEach(T.allCases, id: \.self) { tab in
                Button {
                    withAnimation(Anim.normal) {
                        selection = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(Theme.buttonFont)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selection == tab ? Theme.accentColor.opacity(0.3) : Color.clear)
                        )
                        .foregroundStyle(selection == tab ? Theme.primaryText : Theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(Color.black.opacity(0.2))
        )
    }
}

// MARK: - Hover Button

struct HoverButton: View {
    let icon: String
    let label: String?
    let color: Color
    let action: () -> Void

    @State private var isHovering = false

    init(icon: String, label: String? = nil, color: Color = Theme.primaryText, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                if let label {
                    Text(label)
                }
            }
            .font(Theme.captionFont)
            .foregroundStyle(isHovering ? Theme.primaryText : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.buttonRadius)
                    .fill(isHovering ? Theme.buttonHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Anim.fast) { isHovering = hovering }
        }
    }
}
