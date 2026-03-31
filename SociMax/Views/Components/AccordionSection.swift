import SwiftUI

struct AccordionSection<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    var badge: String? = nil
    var badgeColor: Color = Theme.secondaryText
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Button {
                withAnimation(Anim.normal) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(iconColor)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryText)

                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badgeColor.opacity(0.15))
                            .foregroundStyle(badgeColor)
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Content
            if isExpanded {
                DarkDivider()
                    .padding(.horizontal, 12)

                content()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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

// MARK: - Save Button

struct SaveButton: View {
    let hasChanges: Bool
    let isSaving: Bool
    let showSuccess: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if showSuccess {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(.white)
                }
                Text(isSaving ? "Saving..." : showSuccess ? "Saved!" : "Save Changes")
                    .foregroundStyle(.white)
            }
            .font(Theme.buttonFont)
            .frame(minWidth: 130)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.buttonRadius)
                    .fill(
                        showSuccess
                            ? AnyShapeStyle(Theme.success)
                            : (hasChanges && !isSaving)
                                ? AnyShapeStyle(Theme.accentGradient)
                                : AnyShapeStyle(Theme.cardBackgroundColor)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.buttonRadius)
                    .strokeBorder(Theme.borderColor, lineWidth: showSuccess || (hasChanges && !isSaving) ? 0 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasChanges || isSaving)
        .animation(Anim.fast, value: showSuccess)
        .animation(Anim.fast, value: hasChanges)
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundStyle(Theme.primaryText)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.borderColor, lineWidth: 1)
        )
    }
}

// MARK: - Loading Overlay

struct LoadingOverlay: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accentColor)
            Text(message)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
