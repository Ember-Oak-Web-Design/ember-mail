import SwiftUI

struct WelcomeView: View {
    @Environment(AppState.self) private var app
    @State private var showIMAP = false
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 28) {
            RoundedRectangle(cornerRadius: 26)
                .fill(LinearGradient(colors: [Theme.accent, Theme.oak], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 110, height: 110)
                .overlay(Image(systemName: "envelope.fill").font(.system(size: 50)).foregroundStyle(.white))
                .shadow(color: Theme.accent.opacity(0.35), radius: 20, y: 10)

            VStack(spacing: 8) {
                Text("Welcome to Ember Mail").font(.largeTitle.weight(.bold))
                Text("Your business inbox, Gmail and Google Calendar in one place, with read receipts on every email.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            HStack(spacing: 16) {
                OnboardingCard(title: "Business email", subtitle: "IMAP / SMTP", symbol: "building.2.fill", color: Theme.accent) {
                    showIMAP = true
                }
                OnboardingCard(title: "Google account", subtitle: "Gmail + Calendar", symbol: "g.circle.fill", color: .blue) {
                    Task {
                        connecting = true
                        error = nil
                        do { try await app.addGoogleAccount() } catch { self.error = error.localizedDescription }
                        connecting = false
                    }
                }
            }

            if connecting {
                HStack { ProgressView().controlSize(.small); Text("Finish signing in in your browser…").foregroundStyle(.secondary) }
            }
            if let error {
                VStack(spacing: 6) {
                    Text(error).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                    SettingsLink { Text("Open Settings") }
                }
                .frame(maxWidth: 460)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .sheet(isPresented: $showIMAP) { AddIMAPAccountSheet() }
    }
}

private struct OnboardingCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(color)
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 200, height: 140)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(hovering ? color.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1.5))
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.snappy(duration: 0.2), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
