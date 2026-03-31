import SwiftUI

// MARK: - Onboarding Steps

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case apiKeys = 1
    case howItWorks = 2
    case ready = 3
}

// MARK: - Main Onboarding View

struct OnboardingView: View {
    @State private var currentStep: OnboardingStep = .welcome
    @State private var openaiKey = ""
    @State private var grokKey = ""
    @State private var claudeKey = ""
    @State private var showCheckmark = false
    var onComplete: () -> Void

    var body: some View {
        ZStack {
            Theme.backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                // Content area
                Group {
                    switch currentStep {
                    case .welcome:
                        welcomeStep
                    case .apiKeys:
                        apiKeysStep
                    case .howItWorks:
                        howItWorksStep
                    case .ready:
                        readyStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

                DarkDivider()

                // Bottom bar with dots and navigation
                HStack {
                    // Back button (hidden on first step)
                    if currentStep.rawValue > 0 {
                        Button {
                            withAnimation(Anim.normal) {
                                currentStep = OnboardingStep(rawValue: currentStep.rawValue - 1) ?? .welcome
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                            .font(Theme.buttonFont)
                            .foregroundStyle(Theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Spacer().frame(width: 60)
                    }

                    Spacer()

                    // Progress dots
                    HStack(spacing: 8) {
                        ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                            Circle()
                                .fill(step == currentStep ? Theme.accentColor : Theme.tertiaryText)
                                .frame(width: step == currentStep ? 8 : 6, height: step == currentStep ? 8 : 6)
                                .animation(Anim.fast, value: currentStep)
                        }
                    }

                    Spacer()

                    // Next/Skip/Finish button
                    if currentStep == .ready {
                        Spacer().frame(width: 60)
                    } else if currentStep == .apiKeys {
                        HStack(spacing: 12) {
                            Button("Skip") {
                                withAnimation(Anim.normal) {
                                    currentStep = .howItWorks
                                }
                            }
                            .font(Theme.buttonFont)
                            .foregroundStyle(Theme.tertiaryText)
                            .buttonStyle(.plain)

                            nextButton
                        }
                    } else {
                        nextButton
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 500, height: 450)
        .preferredColorScheme(.dark)
    }

    // MARK: - Next Button

    private var nextButton: some View {
        Button {
            advance()
        } label: {
            HStack(spacing: 4) {
                Text(currentStep == .welcome ? "Get Started" : "Continue")
                Image(systemName: "chevron.right")
            }
            .font(Theme.buttonFont)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.buttonRadius)
                    .fill(Theme.accentGradient)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()

            // Logo
            ZStack {
                Circle()
                    .fill(Theme.accentColor.opacity(0.15))
                    .frame(width: 80, height: 80)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.accentGradient)
            }

            Text("SociMax")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.primaryText)

            Text("AI-Powered Telegram Automation")
                .font(.system(size: 15))
                .foregroundStyle(Theme.accentColor)

            VStack(spacing: 8) {
                Text("Curate content from hundreds of sources,")
                Text("score with AI, and auto-publish to your")
                Text("Telegram channels.")
            }
            .font(Theme.bodyFont)
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)

            Text("v1.0.0")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.top, 4)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Step 2: API Keys

    private var apiKeysStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API Keys")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .padding(.top, 20)

            Text("SociMax uses AI to score and generate content. Add at least one API key to get started.")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.secondaryText)

            ScrollView {
                VStack(spacing: 10) {
                    onboardingKeyCard(
                        name: "OpenAI",
                        subtitle: "GPT-4.1-mini — Best value",
                        icon: "brain",
                        color: Theme.success,
                        key: $openaiKey,
                        getKeyURL: "https://platform.openai.com/api-keys"
                    )

                    onboardingKeyCard(
                        name: "Grok (xAI)",
                        subtitle: "grok-3-mini — Fast & capable",
                        icon: "sparkle",
                        color: Theme.accentColor,
                        key: $grokKey,
                        getKeyURL: nil
                    )

                    onboardingKeyCard(
                        name: "Claude (Anthropic)",
                        subtitle: "Sonnet 4 — Best quality",
                        icon: "text.bubble",
                        color: Theme.warning,
                        key: $claudeKey,
                        getKeyURL: "https://console.anthropic.com/settings/keys"
                    )
                }
            }
        }
        .padding(.horizontal, 30)
    }

    @ViewBuilder
    private func onboardingKeyCard(name: String, subtitle: String, icon: String, color: Color, key: Binding<String>, getKeyURL: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                if let url = getKeyURL {
                    Link(destination: URL(string: url)!) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.right")
                            Text("Get Key")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accentColor)
                    }
                }
            }

            SecureField("API Key", text: key)
                .darkTextField()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.borderColor, lineWidth: 1)
        )
    }

    // MARK: - Step 3: How It Works

    private var howItWorksStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("How It Works")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.primaryText)

            HStack(spacing: 16) {
                featureCard(
                    icon: "globe",
                    color: .teal,
                    title: "Add Sources",
                    description: "RSS feeds, websites, YouTube channels"
                )

                Image(systemName: "arrow.right")
                    .foregroundStyle(Theme.tertiaryText)

                featureCard(
                    icon: "brain",
                    color: Theme.accentColor,
                    title: "AI Scoring",
                    description: "Virality & relevance analysis"
                )

                Image(systemName: "arrow.right")
                    .foregroundStyle(Theme.tertiaryText)

                featureCard(
                    icon: "paperplane.fill",
                    color: .cyan,
                    title: "Auto Publish",
                    description: "Direct to Telegram channels"
                )
            }
            .padding(.horizontal, 20)

            Text("SociMax runs in your menu bar 24/7, automatically curating and publishing the best content for your audience.")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            Spacer()
        }
    }

    @ViewBuilder
    private func featureCard(icon: String, color: Color, title: String, description: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(color)
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primaryText)

            Text(description)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 4: Ready

    private var readyStep: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Theme.success.opacity(0.15))
                    .frame(width: 80, height: 80)
                    .scaleEffect(showCheckmark ? 1.0 : 0.5)
                    .opacity(showCheckmark ? 1 : 0)

                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(Theme.success)
                    .scaleEffect(showCheckmark ? 1.0 : 0.3)
                    .opacity(showCheckmark ? 1 : 0)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showCheckmark)

            Text("You're All Set!")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.primaryText)

            Text("SociMax is ready to automate your Telegram channels. Create your first project to get started.")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                onComplete()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                    Text("Open SociMax")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: Theme.buttonRadius)
                        .fill(Theme.accentGradient)
                )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                showCheckmark = true
            }
        }
    }

    // MARK: - Navigation

    private func advance() {
        // Save API keys if on step 2
        if currentStep == .apiKeys {
            saveAPIKeys()
        }

        withAnimation(Anim.normal) {
            if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
                currentStep = next
            }
        }
    }

    private func saveAPIKeys() {
        if !openaiKey.isEmpty {
            KeychainService.shared.set(key: "openai_api_key", value: openaiKey)
        }
        if !grokKey.isEmpty {
            KeychainService.shared.set(key: "grok_api_key", value: grokKey)
        }
        if !claudeKey.isEmpty {
            KeychainService.shared.set(key: "claude_api_key", value: claudeKey)
        }
    }
}
