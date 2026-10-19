// UI-5: an anonymous install counter — a no-op stub.
// Reporting appears together with signed builds (an ad-hoc bundle has no
// identity for honest anonymous statistics). The toggle on the System screen
// already writes config.telemetry so the behavior turns on without a UI rebuild.
import Foundation

public enum Telemetry {
    /// Called at app start when config.telemetry == true.
    /// Currently a no-op: no network, no identifier, no server.
    public static func pingInstall() {
        // no-op until signed builds
    }
}
