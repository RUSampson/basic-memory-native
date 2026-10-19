// UI-6: the global hotkey search panel. An NSPanel (.nonactivatingPanel,
// floating) above any app, invoked by the global hotkey from config.hotkey
// (Carbon RegisterEventHotKey, no external dependencies). The query logic is
// PanelSearchModel from BMemAPI (tests are there); here only the window, the hotkey and hosting.
import AppKit
import Carbon.HIToolbox
import SwiftUI
import BMemAPI

@MainActor
final class HotkeyPanelController: ObservableObject {
    static let shared = HotkeyPanelController()

    /// Hotkey registration diagnostics for the System screen: nil — all quiet.
    /// The fact is stored, not a string (UI-8): the text is rendered in the
    /// current language in registerErrorText, a language switch updates it without re-registration.
    enum HotkeyIssue {
        case busy(display: String, status: OSStatus)
        case unparsed(raw: String, applied: String)
    }
    @Published private(set) var hotkeyIssue: HotkeyIssue?
    var registerErrorText: String? {
        switch hotkeyIssue {
        case .busy(let display, let status): return Lf("sys.hotkey.busy", display, Int(status))
        case .unparsed(let raw, let applied): return Lf("sys.hotkey.unparsed", raw, applied)
        case nil: return nil
        }
    }
    /// The active hotkey (for the status line on the System screen).
    @Published private(set) var activeHotkey: String?
    @Published private(set) var visible = false

    let model = PanelSearchModel()

    private var panel: NSPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var currentCombo: ParsedHotkey?
    private var configPollTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var handlerRef: EventHandlerRef?

    private init() {
        model.fetch = { query, trust in
            try await HotkeyPanelController.fetchSearch(query: query, trust: trust)
        }
    }

    /// Called from AppDelegate at startup. Registers the hotkey, starts the
    /// config polling (a hotkey change on the System screen applies on the fly).
    func start() {
        installEventHandlerIfNeeded()
        Task { [weak self] in
            guard let self else { return }
            // Wait for the first config in short steps: the daemon may have
            // started later than the app; without a config we live on the default ⌥Space.
            for _ in 0..<20 {
                await self.pollConfigOnce()
                if self.currentCombo != nil { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if self.currentCombo == nil {
                self.apply(hotkeyString: nil)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self.pollConfigOnce()
            }
        }
    }

    // MARK: - Hotkey

    private func apply(hotkeyString: String?) {
        let (combo, fellBack) = HotkeyParser.resolve(configValue: hotkeyString)
        if let currentCombo, currentCombo.keyCode == combo.keyCode,
           currentCombo.carbonModifiers == combo.carbonModifiers { return }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        let id = EventHotKeyID(signature: OSType(0x424D454D) /* 'BMEM' */, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers,
                                         id, GetEventDispatcherTarget(), 0, &hotKeyRef)
        currentCombo = combo
        activeHotkey = combo.display
        if status != noErr {
            hotkeyIssue = .busy(display: combo.display, status: status)
            NSLog("BMem hotkey: RegisterEventHotKey(\(combo.display)) -> \(status)")
        } else {
            hotkeyIssue = fellBack
                ? .unparsed(raw: hotkeyString ?? "", applied: combo.display)
                : nil
            NSLog("%@", Lf("log.hotkey.registered", combo.display))
        }
    }

    private func pollConfigOnce() async {
        var request = URLRequest(url: DaemonEndpoint.base.appendingPathComponent("v1/config"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let cfg = try? JSONDecoder().decode(DaemonConfig.self, from: data)
        else { return }
        apply(hotkeyString: cfg.hotkey)
    }

    private func installEventHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData -> OSStatus in
            if let userData {
                let controller = Unmanaged<HotkeyPanelController>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { controller.toggle() }
            }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
        NSLog("BMem hotkey: InstallEventHandler -> \(status)")
    }

    // MARK: - Panel

    func toggle() {
        if visible { hide() } else { show() }
    }

    func show() {
        let panel = ensurePanel()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        visible = true
        installKeyMonitorIfNeeded()
        model.focusRequest += 1
    }

    func hide() {
        panel?.orderOut(nil)
        visible = false
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = HotkeyPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

        let host = NSHostingView(rootView: HotkeyPanelView()
            .environmentObject(model)
            .environmentObject(self))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        p.contentView = blur
        // contentRect of .titled includes the titlebar — the footer slid off
        // the edge; set exactly the content area 640x480.
        p.setContentSize(NSSize(width: 640, height: 480))
        panel = p
        return p
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let x = screen.frame.midX - size.width / 2
        let y = screen.visibleFrame.maxY - size.height - 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// The panel keyboard: up/down select, Enter opens, ⌘Enter opens without
    /// focus, Esc hides. A local monitor — the panel is key, but the app is not active.
    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.visible else { return event }
            let code = event.keyCode
            let cmd = event.modifierFlags.contains(.command)
            switch code {
            case UInt16(kVK_Escape):
                self.hide(); return nil
            case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
                if cmd { self.openSelected(activate: false) } else { self.openSelected(activate: true) }
                return nil
            case UInt16(kVK_UpArrow):
                self.model.moveSelection(by: -1); return nil
            case UInt16(kVK_DownArrow):
                self.model.moveSelection(by: 1); return nil
            default:
                return event
            }
        }
    }

    func openSelected(activate: Bool) {
        guard let row = model.selectedRow else { hide(); return }
        let url = URL(fileURLWithPath: row.filePath)
        if activate {
            NSWorkspace.shared.open(url)
        } else {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open([url], withApplicationAt: defaultApp(for: url),
                                    configuration: config)
        }
        hide()
    }

    /// The default app for ⌘↵ («open in a neighboring app without focus»):
    /// take the LaunchServices association without activating it.
    private func defaultApp(for url: URL) -> URL {
        NSWorkspace.shared.urlForApplication(toOpen: url)
            ?? NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/"))
            ?? URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    }

    // MARK: - Manual run (DoD): --panel-shot=path --panel-query=text

    /// Manual run (DoD). Shows the panel, enters the query, waits for hits,
    /// captures the panel to PNG and exits. The from-inside shot (cacheDisplay)
    /// is the same Screen Recording TCC bypass as the UI-2..5 click tests.
    ///
    /// With the --panel-wait-hotkey flag the panel is NOT shown by itself: we
    /// wait until the global hotkey raises it (the stand script sends a CGEvent)
    /// — so the shot proves both the hotkey and the panel. If we do not wait it
    /// out — we show it by hand and write honestly to stderr. In the agent
    /// headless session WindowServer filters synthetic events from senders
    /// without Accessibility — there the fallback always fires, in a live user session — the hotkey.
    func runPanelShot(path: String, query: String, waitHotkey: Bool) {
        Task { @MainActor in
            // Give the polling time to register the hotkey from the stand config.
            try? await Task.sleep(for: .seconds(2))
            if waitHotkey {
                for _ in 0..<120 where !visible {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if !visible {
                    stderrLog(L("log.panel.hotkeyTimeout") + "\n")
                    show()
                } else {
                    stderrLog(L("log.panel.hotkeyFired") + "\n")
                }
            } else {
                show()
            }
            // Write the query into the model before showing (onAppear pulls it
            // into the field), and trigger the search after — the panel is on screen.
            model.setQuery(query)
            if !visible { show() }
            model.searchNow()
            for _ in 0..<60 where model.rows.isEmpty && model.lastError == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .milliseconds(400))
            guard let panel, let content = panel.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            else {
                stderrLog(L("log.panel.noShot") + "\n")
                exit(2)
            }
            panel.displayIfNeeded()
            content.cacheDisplay(in: content.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            let ms = model.lastLatencyMs ?? -1
            stderrLog(Lf("log.panel.summary", model.rows.count,
                         String(format: "%.0f", ms), activeHotkey ?? "?") + "\n")
            exit(0)
        }
    }

    // MARK: - Transport

    static func fetchSearch(query: String, trust: String) async throws -> PanelSearchResponse {
        var comps = URLComponents(url: DaemonEndpoint.base.appendingPathComponent("v1/search"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "q", value: query),
                            URLQueryItem(name: "trust", value: trust),
                            URLQueryItem(name: "limit", value: "8")]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 30
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw PanelFetchError(Lf("panel.fetch.http", (response as? HTTPURLResponse)?.statusCode ?? -1))
            }
            return try JSONDecoder().decode(PanelSearchResponse.self, from: data)
        } catch let urlError as URLError {
            // A human line instead of an NSError dump (see the first run shot).
            switch urlError.code {
            case .timedOut: throw PanelFetchError(L("panel.fetch.timeout"))
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                throw PanelFetchError(L("panel.fetch.dead"))
            default: throw PanelFetchError(urlError.localizedDescription)
            }
        }
    }
}

/// The panel must accept the keyboard without activating the app (Spotlight mode).
final class HotkeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
