// Shutdown drain fix: SIGTERM/SIGINT handlers OUTSIDE top-level code in main.swift.
//
// Same defect class as FIX-6 (MemoryPressureMonitor.swift): top-level code is
// isolated to MainActor (SE-0438), and a closure written in it is inferred
// MainActor-isolated; GCD calls the signal handler on a utility queue,
// the isolation check (swift_task_checkIsolated -> dispatch_assert_queue)
// fires BEFORE the first gracefulExit line — SIGTERM/SIGINT dropped the fixed
// daemon with SIGTRAP (rc=133), the drain never happened at all (regression
// repro bmem-2026-10-18-151909.ips and teardown reports from ControlAPITests).
// The controlShutdown path (asyncAfter from a nonisolated ControlAPI.swift function)
// did not crash exactly because its closure is nonisolated — same trick here:
// the closure is created in a nonisolated init, requires no isolation
// (SIL verification is in the card report).
import Dispatch
import Foundation

/// Owner of the two dispatch sources for graceful shutdown. Held by a
/// top-level let of the daemon: releasing it early would cancel the sources
/// (same as before the move — termSource/intSource lived in top-level).
final class SignalShutdownMonitor {
    private let sources: [DispatchSourceSignal]

    init() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM,
                                                   queue: DispatchQueue.global(qos: .utility))
        term.setEventHandler { gracefulExit("SIGTERM") }
        let int = DispatchSource.makeSignalSource(signal: SIGINT,
                                                  queue: DispatchQueue.global(qos: .utility))
        int.setEventHandler { gracefulExit("SIGINT") }
        term.resume()
        int.resume()
        sources = [term, int]
    }
}
