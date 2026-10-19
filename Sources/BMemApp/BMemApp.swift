import SwiftUI
import AppKit
import BMemAPI

/// Launch-argument parsing: accepts both `--flag value` and `--flag=value`.
/// The `=` form is not cosmetic: `open -n App --args --flag value` sometimes
/// wraps «value» into an odoc event (open document), and the SwiftUI
/// WindowGroup then creates no scene at all (caught 15.10 in the click test:
/// the window never appears, the scene body never evaluates). The click test passes only the `=` form.
func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    let eq = "--" + name + "="
    if let hit = args.first(where: { $0.hasPrefix(eq) }) { return String(hit.dropFirst(eq.count)) }
    if let i = args.firstIndex(of: "--" + name), i + 1 < args.count { return args[i + 1] }
    return nil
}

@main
struct BMemAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("onboardingDone") private var onboardingDone = false
    @StateObject private var daemon = DaemonModel()

    /// The click test also captures the main screen: --skip-onboarding without resetting the flag.
    private var skipOnboarding: Bool {
        CommandLine.arguments.contains("--skip-onboarding")
    }

    /// Click test only: show onboarding when the config is non-empty.
    private var forceOnboarding: Bool {
        CommandLine.arguments.contains("--force-onboarding")
    }

    /// UI-3 rule: show onboarding when the daemon config has not a single
    /// folder. While the config is unread (the daemon is silent) — fall back
    /// to the local «onboarding done» flag.
    private var showOnboarding: Bool {
        if forceOnboarding { return true }
        if skipOnboarding { return false }
        if let cfg = daemon.config { return cfg.projects.isEmpty }
        return !onboardingDone
    }

    /// Click test: --win-height=N — capture the whole screen when the content
    /// is taller than the default window (reference 06 with the «What goes where» table).
    private var winHeight: CGFloat {
        CGFloat(Double(argValue("win-height") ?? "") ?? 640)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showOnboarding {
                    OnboardingView { onboardingDone = true }
                } else {
                    RootView()
                }
            }
            .environmentObject(daemon)
            .task { await daemon.pollLoop() }
            .frame(minWidth: 860, minHeight: 560)
            .preferredColorScheme(.dark)
        }
        .defaultSize(width: 960, height: winHeight)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // From a terminal/script without activation the window does not come to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Click test for the Advanced screen: show the key field filled in
        // (reference 06). Written by THIS SAME binary into the login keychain —
        // readable without an ACL prompt; the stand script deletes the record after the shot.
        if CommandLine.arguments.contains("--seed-lan-key") {
            Task.detached(priority: .userInitiated) {
                _ = try? BMemKeychain.save(account: BMemKeychain.lanKeyAccount,
                                           value: "bmem-demo-" + String(BMemKeychain.generateAPIKey().prefix(12)))
            }
        }

        // UI-6: the global hotkey panel — lives regardless of the window state
        // (closing the window does not kill the app, see applicationShouldTerminate…).
        HotkeyPanelController.shared.start()
        if let shot = argValue("panel-shot") {
            HotkeyPanelController.shared.runPanelShot(
                path: shot,
                query: argValue("panel-query") ?? L("panel.defaultQuery"),
                waitHotkey: CommandLine.arguments.contains("--panel-wait-hotkey"))
        }

        // Click test: --screenshot <path> — capture the window from inside the
        // app (cacheDisplay needs no Screen Recording TCC, unlike screencapture
        // from a headless session) and exit.
        if let path = argValue("screenshot") {
            Task { @MainActor in
                // 4.5 s — the UI-3/UI-5 screens pull the config, compute sizes
                // from disk and fetch the benchmark in the background; the shot
                // must catch live data even under load (daemon warm-indexing nearby).
                try? await Task.sleep(for: .seconds(4.5))
                await self.captureMainWindow(to: path)
            }
        }
    }

    @MainActor
    private func captureMainWindow(to path: String) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
        else {
            stderrLog(L("log.shot.noWindow") + "\n")
            exit(2)
        }
        // --win-height=N: defaultSize does not override the saved window frame,
        // so for the shot we stretch the window by hand and give the frame a layout pass.
        if let hStr = argValue("win-height"), let h = Double(hStr), h >= 560 {
            window.setContentSize(NSSize(width: max(window.frame.width, 960), height: h))
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else {
            stderrLog(L("log.shot.noWindow") + "\n")
            exit(2)
        }
        window.displayIfNeeded()
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            stderrLog(L("log.shot.noRep") + "\n")
            exit(2)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            exit(0)
        } catch {
            stderrLog(Lf("log.shot.writeFailed", path, String(describing: error)) + "\n")
            exit(2)
        }
    }

    /// UI-6: the panel must be invocable even with the main window closed —
    /// the last closed window does not kill the app (stand captures exit via
    /// exit() themselves, this does not affect them).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
