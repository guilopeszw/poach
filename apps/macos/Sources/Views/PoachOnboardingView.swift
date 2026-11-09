import AppKit
import SwiftUI

struct PoachOnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            hero

            featureRows

            Button(action: onContinue) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PoachActionStyle(fill: PoachPalette.ink, foreground: .white))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .background(alignment: .top) {
            RadialGradient(
                colors: [Color(red: 0.90, green: 0.86, blue: 0.81), PoachPalette.canvas],
                center: .top,
                startRadius: 0,
                endRadius: 255
            )
            .ignoresSafeArea(edges: .top)
            .accessibilityHidden(true)
        }
        .background(PoachPalette.canvas)
        .preferredColorScheme(.light)
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 68, height: 68)
                .accessibilityHidden(true)

            Text("Welcome to Poach")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .tracking(-0.5)
                .accessibilityAddTraits(.isHeader)

            Text("Record an interaction and show your assistant how it works.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var featureRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingFeatureRow(
                symbol: "record.circle",
                title: "Record the screen",
                detail: "Record a selected area, window, or the full screen."
            )
            OnboardingFeatureRow(
                symbol: "cursorarrow.click.2",
                title: "Capture clicks and drags",
                detail: "Pointer movement, clicks, and drags stay with the recording."
            )
            OnboardingFeatureRow(
                symbol: "text.bubble",
                title: "Leave notes on the timeline",
                detail: "Comment at the exact moment you want your agent to notice."
            )
            OnboardingFeatureRow(
                symbol: "link",
                title: "Hand it to Codex or Claude",
                detail: "Share the recording, notes, and colors through MCP."
            )
        }
    }
}

private struct OnboardingFeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(PoachPalette.ink)
                .frame(width: 38, height: 38)
                .background(PoachPalette.inset, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PoachPalette.ink)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
