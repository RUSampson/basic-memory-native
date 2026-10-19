// Daemon lifecycle fix: one source of truth for the numbers both the daemon and the UI see.
// BMemAPI is a lightweight dependency-free target: both BMemCore (daemon)
// and BMemApp (facade, links without CoreAIKit/SQLite) link it. Numbers that
// must match between /v1/status and interface strings live only here.

public enum BMemTuning {
    /// Watchdog desync fix: fixed idle-unload threshold of the
    /// model, seconds. Adaptive auto-tuning is deliberately not introduced into
    /// the product; BMEM_MODEL_IDLE_TIMEOUT overrides for stands only.
    /// The sys.model.unloaded string must show the actual threshold, not a
    /// literal (defect 18.10: the UI promised «90 s» while the live threshold was 335).
    public static let modelIdleTimeoutSeconds: Int = 335

    /// Shutdown drain fix: drain budget for graceful shutdown (SIGTERM/SIGINT/
    /// POST /v1/shutdown), seconds. The previous 15 s reliably dropped an
    /// in-flight cold request: a cold embed-reload costs 60-90 s (the watchdog desync fix
    /// number), and the daemon exited with «drain timeout, exiting anyway»
    /// leaving the client with rc=52. Data is not lost meanwhile (WAL +
    /// runFailures/rescan), but a client must get an answer once the request started.
    /// The owning app daemon-replacement cycle is not slowed by this budget:
    /// its own ladder POST /v1/shutdown -> 20 s -> SIGTERM -> 20 s -> SIGKILL
    /// takes a long-draining daemon down hard, while the long budget helps the
    /// «soft» stops (manual kill, launchd,
    /// test teardown).
    public static let shutdownDrainSeconds: Int = 90
}
