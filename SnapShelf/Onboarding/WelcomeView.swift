import SwiftUI

/// Shown once, on first launch (and reachable again later only if `hasCompletedOnboarding` is
/// reset). A single calm screen: enable capture redirection, optionally hide the floating
/// thumbnail and register launch-at-login, then — once enabled — offer a one-tap Desktop cleanup.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    /// Local UI-only until "Save Screenshots to SnapShelf" is pressed — the plan is explicit that
    /// the floating-thumbnail setting is only touched then, never live while the user is still
    /// deciding.
    @State private var importInstantly = false
    @State private var launchAtLogin = false
    @State private var isEnabled = false

    @State private var cleanupScanResult: DesktopCleanupService.ScanResult?
    @State private var isConfirmingCleanup = false
    @State private var cleanupSummary: DesktopCleanupService.CleanupSummary?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            if isEnabled {
                successState
            } else {
                introState
            }

            Text("You can switch back to saving on the Desktop anytime in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 460, height: 560)
        .confirmationDialog(
            "Clean Up Desktop",
            isPresented: $isConfirmingCleanup,
            presenting: cleanupScanResult
        ) { result in
            if result.isEmpty {
                Button("OK", role: .cancel) {}
            } else {
                Button("Move \(result.total) Screenshot\(result.total == 1 ? "" : "s")") {
                    Task { cleanupSummary = await appState.desktopCleanupService.cleanUp(result) }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: { result in
            Text(cleanupMessage(for: result))
        }
    }

    // MARK: - Intro state

    private var introState: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Keep Your Desktop Clear")
                    .font(.title2.weight(.semibold))
                Text(
                    "SnapShelf can save new screenshots straight into its own library instead " +
                    "of your Desktop."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Button("Save Screenshots to SnapShelf") {
                    enable()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Import instantly (hides the macOS floating thumbnail)", isOn: $importInstantly)
                    Toggle("Open SnapShelf at login", isOn: $launchAtLogin)
                }
                .toggleStyle(.checkbox)
                .font(.callout)

                Button("Not Now") {
                    finish()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Success state

    private var successState: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Label("Screenshots now save to SnapShelf", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 10) {
                Button("Clean Up Desktop…") {
                    cleanupScanResult = appState.desktopCleanupService.scanDesktop()
                    isConfirmingCleanup = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if let cleanupSummary {
                    Text(cleanupSummaryText(cleanupSummary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button("Done") {
                    finish()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Actions

    private func enable() {
        appState.captureLocationService.enable()
        if importInstantly {
            appState.captureLocationService.isFloatingThumbnailHidden = true
        }
        if launchAtLogin {
            appState.launchAtLoginService.register()
        }
        isEnabled = true
    }

    private func finish() {
        hasCompletedOnboarding = true
        dismissWindow()
    }

    private func cleanupMessage(for result: DesktopCleanupService.ScanResult) -> String {
        guard !result.isEmpty else {
            return "No screenshots were found on your Desktop."
        }
        var message = "Move \(result.images.count) screenshot\(result.images.count == 1 ? "" : "s") " +
            "into SnapShelf? The originals go to the Trash."
        if !result.movies.isEmpty {
            message += " \(result.movies.count) screen recording\(result.movies.count == 1 ? "" : "s") " +
                "will be moved to ~/Movies/Screen Recordings."
        }
        return message
    }

    private func cleanupSummaryText(_ summary: DesktopCleanupService.CleanupSummary) -> String {
        var parts: [String] = []
        if summary.importedImageCount > 0 {
            parts.append("Moved \(summary.importedImageCount) screenshot\(summary.importedImageCount == 1 ? "" : "s")")
        }
        if summary.movedMovieCount > 0 {
            parts.append("\(summary.movedMovieCount) recording\(summary.movedMovieCount == 1 ? "" : "s")")
        }
        if parts.isEmpty {
            return "Nothing to move."
        }
        return parts.joined(separator: " and ") + "."
    }
}
