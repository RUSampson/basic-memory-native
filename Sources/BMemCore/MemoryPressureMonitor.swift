import Dispatch
import Foundation

/// FIX-6: the owner of the live memory-pressure source (the event part of FIX-4).
///
/// The source and its handler live OUTSIDE top-level code in main.swift. The
/// reason (card FIX-6, reports bmem-2026-10-13..14, six of them): top-level code
/// in Swift 6 is isolated to MainActor (SE-0438), the top-level `let pressureSource`
/// has type `any DispatchSourceMemoryPressure` (a non-Sendable existential) and
/// is therefore MainActor-isolated too; the setEventHandler handler reading
/// `pressureSource.mask` was inferred MainActor-isolated (confirmed in SIL:
/// SIL: `Isolation: global_actor. MainActor` + swift_task_isCurrentExecutor).
/// GCD calls it on a utility queue, the isolation check trips
/// dispatch_assert_queue and the daemon died with SIGTRAP on the first real
/// OS memory warning. Through this class the handler is honestly nonisolated
/// (SIL run: `Isolation: nonisolated`, 0 executor checks); the FIX-4 acceptance
/// FIFO injections did not catch this path — there the call came from a
/// detached thread and required no isolation.
///
/// The level semantics (what the handler does) — Engine.handleMemoryPressure.
public final class MemoryPressureMonitor: Sendable {
    private let source: DispatchSourceMemoryPressure

    public init(engine: Engine) {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        // Capturing the local variable `source` (not a top-level let) is the only
        // way to read .mask without MainActor isolation; the strong reference
        // source->handler->engine matches the previous code behavior.
        source.setEventHandler {
            let level: Engine.MemoryPressure =
                source.mask.contains(.critical) ? .critical : .warning
            Task { await engine.handleMemoryPressure(level) }
        }
        self.source = source
    }

    /// Resume the source (GCD keeps the source alive until cancel, as before).
    public func start() { source.resume() }

    /// Cancel the subscription (for stands/tests; the daemon does not need it — it lives until exit).
    public func cancel() { source.cancel() }
}
