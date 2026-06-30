import SwiftUI

/// The single "Take a break" affordance, shared by the check-in prompt and the
/// menu so every surface escalates on the same rule: a quiet one-liner normally,
/// the prominent card once a break is overdue (`Tracker.isBreakOverdue`).
struct BreakButton: View {
    /// Drives small-vs-big. Pass `tracker.isBreakOverdue`.
    let overdue: Bool
    let timeSinceLastBreak: TimeInterval?
    /// Varied copy for the prominent card — pick once per showing so each nudge
    /// reads as a different attempt rather than the same nag.
    let prompt: BreakPrompt
    let action: () -> Void

    var body: some View {
        if overdue {
            Button(action: action) {
                VStack(spacing: 4) {
                    if let secs = timeSinceLastBreak {
                        Text(secs.hm)
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("since your last break")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: prompt.icon)
                        .font(.title)
                        .padding(.top, 2)
                    Text(prompt.title)
                        .font(.title3.weight(.bold))
                    Text(prompt.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .padding(.horizontal, 14)
                .background(Color.blue.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        } else {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "figure.walk")
                    Text("Take a break")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if let secs = timeSinceLastBreak {
                        Text(secs.hm)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }
}

/// One way of nudging the user to step away. A fresh one is picked each time a
/// break affordance appears so the reminder reads as a different "attempt"
/// rather than the same nag every time.
struct BreakPrompt {
    let icon: String
    let title: String
    let subtitle: String

    static let all: [BreakPrompt] = [
        BreakPrompt(icon: "figure.walk",        title: "Take a break",     subtitle: "Stand up and move for a few minutes"),
        BreakPrompt(icon: "figure.flexibility", title: "Time to stretch",  subtitle: "Roll your shoulders, loosen your neck"),
        BreakPrompt(icon: "eye",                title: "Rest your eyes",   subtitle: "Look at something 20 feet away for 20 seconds"),
        BreakPrompt(icon: "figure.walk",        title: "Go for a wander",  subtitle: "A short walk resets your focus"),
        BreakPrompt(icon: "wind",               title: "Take a breather",  subtitle: "A few slow breaths, then back to it"),
        BreakPrompt(icon: "drop",               title: "Grab some water",  subtitle: "Hydrate and step away for a moment"),
        BreakPrompt(icon: "figure.stand",       title: "Stand up",         subtitle: "Your back will thank you later"),
        BreakPrompt(icon: "sun.max",            title: "Look outside",     subtitle: "Find a window and let your eyes relax"),
    ]

    static func random() -> BreakPrompt { all.randomElement() ?? all[0] }
}
