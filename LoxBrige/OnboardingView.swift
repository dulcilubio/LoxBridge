import SwiftUI

/// Shown on first launch (and after a factory reset) to present the privacy notice
/// and guide the user through the two required setup steps:
/// (1) privacy consent, (2) authorize HealthKit, (3) connect Livelox.
struct OnboardingView: View {
    @ObservedObject var model: AppViewModel
    /// Persisted flag: once true, onboarding is not shown again.
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @State private var currentStep = 0
    @State private var completedSteps: Set<Int> = []
    @State private var showFullPrivacy = false

    private let steps: [OnboardingStep] = [
        OnboardingStep(
            systemImage: "hand.raised.fill",
            imageColor: .blue,
            title: "Your Privacy",
            description: "LoxBridge reads your workout GPS routes from Apple Health and sends them to Livelox — only when you choose. Your data never goes anywhere else, is never sold, and is never used for advertising.",
            actionTitle: "I Understand & Continue"
        ),
        OnboardingStep(
            systemImage: "heart.fill",
            imageColor: .red,
            title: "Connect Apple Health",
            description: "LoxBridge reads your Apple Watch and iPhone workout routes through the Apple Health app to generate GPX files. Tap below to grant access.",
            actionTitle: "Authorize Health Access"
        ),
        OnboardingStep(
            systemImage: "mappin.and.ellipse",
            imageColor: .accentColor,
            title: "Connect Livelox",
            description: "Sign in to your Livelox account so routes can be uploaded automatically after each workout.",
            actionTitle: "Connect Livelox"
        ),
        OnboardingStep(
            systemImage: "checkmark.seal.fill",
            imageColor: .green,
            title: "All Set!",
            description: "LoxBridge will run in the background. After each outdoor workout you'll receive a notification to upload the route.",
            actionTitle: "Get Started"
        )
    ]

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            let step = steps[currentStep]

            Image(systemName: step.systemImage)
                .font(.system(size: 60))
                .foregroundStyle(step.imageColor)

            VStack(spacing: 12) {
                Text(step.title)
                    .font(.title2)
                    .bold()
                    .multilineTextAlignment(.center)

                Text(step.description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // Show a "Full Privacy Notice" link on the privacy step only.
                if currentStep == 0 {
                    Button("View Full Privacy Notice") {
                        showFullPrivacy = true
                    }
                    .font(.footnote)
                    .padding(.top, 4)
                }
            }

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            Button(step.actionTitle) {
                Task { await handleAction(for: currentStep) }
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)

            // Livelox can be connected later in Settings.
            if currentStep == 2 {
                Button("Skip for now") {
                    currentStep = 3
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            // Step indicator: numbered circles that reflect completion state
            HStack(spacing: 16) {
                ForEach(steps.indices, id: \.self) { index in
                    OnboardingStepIndicator(
                        number: index + 1,
                        state: stepState(for: index)
                    )
                }
            }
            .padding(.bottom)
        }
        .padding()
        .sheet(isPresented: $showFullPrivacy) {
            NavigationStack {
                PrivacyView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showFullPrivacy = false }
                        }
                    }
            }
        }
    }

    // MARK: - Step state

    private func stepState(for index: Int) -> OnboardingStepState {
        if completedSteps.contains(index) { return .completed }
        if index == currentStep { return model.lastError != nil ? .failed : .active }
        return .upcoming
    }

    // MARK: - Action handling

    private func handleAction(for step: Int) async {
        model.lastError = nil
        switch step {
        case 0:
            // Privacy consent — no async work needed, just advance.
            completedSteps.insert(0)
            currentStep = 1
        case 1:
            await model.requestHealthKitAuthorization()
            if model.lastError == nil || model.healthKitStatus == "Authorized" {
                completedSteps.insert(1)
                currentStep = 2
            }
        case 2:
            await model.connectLivelox()
            if model.liveloxStatus == "Connected" {
                completedSteps.insert(2)
                currentStep = 3
            }
        case 3:
            completedSteps.insert(3)
            onboardingCompleted = true
        default:
            onboardingCompleted = true
        }
    }
}

// MARK: - Step state (file-private so OnboardingStepIndicator can use it)

private enum OnboardingStepState: Equatable {
    case upcoming, active, failed, completed
}

// MARK: - Step indicator

private struct OnboardingStepIndicator: View {
    let number: Int
    let state: OnboardingStepState

    var body: some View {
        ZStack {
            Circle()
                .fill(circleColor)
                .frame(width: 36, height: 36)

            if state == .completed {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(number)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(labelColor)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    private var circleColor: Color {
        switch state {
        case .upcoming:   return Color(.systemGray5)
        case .active:     return .accentColor
        case .failed:     return .red
        case .completed:  return .green
        }
    }

    private var labelColor: Color {
        switch state {
        case .upcoming:   return Color(.secondaryLabel)
        case .active, .failed, .completed: return .white
        }
    }
}

// MARK: - Step model

private struct OnboardingStep {
    let systemImage: String
    let imageColor: Color
    let title: String
    let description: String
    let actionTitle: String
}

#Preview {
    OnboardingView(model: AppViewModel())
}
