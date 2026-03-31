import SwiftUI

enum Theme {
    // MARK: - Backgrounds
    static let backgroundColor = Color(red: 0.11, green: 0.11, blue: 0.14)
    static let cardBackgroundColor = Color(red: 0.15, green: 0.15, blue: 0.18)
    static let inputBackgroundColor = Color(red: 0.13, green: 0.13, blue: 0.16)

    // MARK: - Accent (Blue/Cyan)
    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 0.20, green: 0.50, blue: 0.90),
            Color(red: 0.30, green: 0.70, blue: 0.95)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let accentColor = Color(red: 0.25, green: 0.60, blue: 0.92)

    // MARK: - Text
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.7)
    static let tertiaryText = Color.white.opacity(0.4)

    // MARK: - Borders & Surfaces
    static let borderColor = Color.white.opacity(0.1)
    static let cardHover = Color.white.opacity(0.08)
    static let buttonHover = Color.white.opacity(0.15)

    // MARK: - Semantic
    static let success = Color(red: 0.30, green: 0.78, blue: 0.40)
    static let error = Color(red: 0.90, green: 0.30, blue: 0.30)
    static let warning = Color(red: 0.95, green: 0.70, blue: 0.20)

    // MARK: - Corner Radii
    static let popoverRadius: CGFloat = 16
    static let cardRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 8

    // MARK: - Fonts
    static let titleFont: Font = .system(size: 16, weight: .semibold)
    static let bodyFont: Font = .system(size: 14, weight: .regular)
    static let captionFont: Font = .system(size: 12, weight: .regular)
    static let buttonFont: Font = .system(size: 13, weight: .medium)
}
