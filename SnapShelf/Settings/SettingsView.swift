import AppKit
import KeyboardShortcuts
import SwiftData
import SwiftUI

/// General / Capture / Storage preferences. Every mutating control here calls straight into the
/// same services the Welcome window and Library window use — there's no separate "Settings"
/// state, just the current state of those services rendered as controls.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            CaptureSettingsTab()
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }

            StorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: launchAtLoginBinding)
                if appState.launchAtLoginService.status == .requiresApproval {
                    Button("Open Login Items Settings…") {
                        appState.launchAtLoginService.openLoginItemsSettings()
                    }
                    .font(.footnote)
                }

                KeyboardShortcuts.Recorder("Show SnapShelf:", name: .togglePanel)
            }

            Section {
                Toggle("Show floating thumbnail after capture", isOn: showFloatingThumbnailBinding)
                Text("Turning this off imports screenshots instantly, without waiting for the thumbnail to disappear.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { appState.launchAtLoginService.status == .enabled },
            set: { isOn in
                if isOn {
                    appState.launchAtLoginService.register()
                } else {
                    appState.launchAtLoginService.unregister()
                }
            }
        )
    }

    private var showFloatingThumbnailBinding: Binding<Bool> {
        Binding(
            get: { !appState.captureLocationService.isFloatingThumbnailHidden },
            set: { isShown in appState.captureLocationService.isFloatingThumbnailHidden = !isShown }
        )
    }
}

// MARK: - Capture

private struct CaptureSettingsTab: View {
    @Environment(AppState.self) private var appState

    @State private var cleanupScanResult: DesktopCleanupService.ScanResult?
    @State private var isConfirmingCleanup = false
    @State private var cleanupSummary: DesktopCleanupService.CleanupSummary?

    var body: some View {
        Form {
            Section {
                Label(statusText, systemImage: statusSymbol)

                switch appState.captureLocationService.status {
                case .savingToSnapShelf:
                    Button("Save Screenshots to Desktop") {
                        appState.captureLocationService.restore()
                    }
                case .savingToDesktop, .savingElsewhere:
                    Button("Save Screenshots to SnapShelf") {
                        appState.captureLocationService.enable()
                    }
                }
            }

            Section {
                LabeledContent("Screen recordings") {
                    Text("Moved to ~/Movies/Screen Recordings")
                        .foregroundStyle(.secondary)
                }
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(
                        at: LibraryPaths.screenRecordings,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.open(LibraryPaths.screenRecordings)
                }
            }

            Section {
                Button("Clean Up Desktop…") {
                    cleanupScanResult = appState.desktopCleanupService.scanDesktop()
                    isConfirmingCleanup = true
                }
                if let cleanupSummary {
                    Text(cleanupSummaryText(cleanupSummary))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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

    private var statusText: String {
        switch appState.captureLocationService.status {
        case .savingToSnapShelf: "Saving to SnapShelf"
        case .savingToDesktop: "Saving to Desktop"
        case .savingElsewhere(let url): "Saving to \(url.lastPathComponent)"
        }
    }

    private var statusSymbol: String {
        switch appState.captureLocationService.status {
        case .savingToSnapShelf: "checkmark.circle.fill"
        case .savingToDesktop: "desktopcomputer"
        case .savingElsewhere: "folder"
        }
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
        return parts.isEmpty ? "Nothing to move." : parts.joined(separator: " and ") + "."
    }
}

// MARK: - Storage

private struct StorageSettingsTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<Screenshot> { $0.deletedAt == nil })
    private var activeScreenshots: [Screenshot]

    @AppStorage("retentionDays") private var retentionDays = 0
    @State private var libraryByteCount: Int64?
    @State private var isConfirmingEmptyRecentlyDeleted = false

    var body: some View {
        Form {
            Section {
                Picker("Keep screenshots", selection: $retentionDays) {
                    Text("Forever").tag(0)
                    Text("1 Year").tag(365)
                    Text("90 Days").tag(90)
                    Text("30 Days").tag(30)
                }
                .onChange(of: retentionDays) {
                    appState.retentionService.applyRetentionPolicy()
                }
                Text("Favorites are never removed automatically. Items in Recently Deleted are removed after 30 days.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Screenshots", value: "\(activeScreenshots.count)")
                LabeledContent("Library size") {
                    if let libraryByteCount {
                        Text(Self.byteCountFormatter.format(libraryByteCount))
                    } else {
                        Text("Calculating…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Empty Recently Deleted…") {
                    isConfirmingEmptyRecentlyDeleted = true
                }
            }
        }
        .formStyle(.grouped)
        .task {
            libraryByteCount = await Self.computeLibrarySize()
        }
        .confirmationDialog(
            "Empty Recently Deleted?",
            isPresented: $isConfirmingEmptyRecentlyDeleted
        ) {
            Button("Empty Recently Deleted", role: .destructive) { emptyRecentlyDeleted() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Screenshots in Recently Deleted will be removed for good. This can't be undone.")
        }
    }

    private func emptyRecentlyDeleted() {
        let descriptor = FetchDescriptor<Screenshot>(predicate: #Predicate<Screenshot> { $0.deletedAt != nil })
        guard let all = try? modelContext.fetch(descriptor) else { return }
        AppState.permanentlyDelete(all, modelContext: modelContext)
    }

    private static let byteCountFormatter: ByteCountFormatStyle = .byteCount(style: .file)

    private static func computeLibrarySize() async -> Int64 {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: LibraryPaths.library, includingPropertiesForKeys: [.fileSizeKey]) else {
                return 0
            }
            var total: Int64 = 0
            while let url = enumerator.nextObject() as? URL {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
            return total
        }.value
    }
}
