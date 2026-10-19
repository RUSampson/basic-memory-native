import SwiftUI
import BMemAPI

/// The Search screen (reference design/screenshots/05-search.png, card UI-5).
/// The strictness slider -> strictness for /v1/search (persist to config.min_similarity),
/// the «Who to trust» segment -> the trust filter, the accuracy benchmark block -> GET /v1/benchmark,
/// «Create your own benchmark» -> POST /v1/benchmark/custom (stored in evals/custom.json).
/// UI-8: strings — Localizable.xcstrings.
struct SearchView: View {
    @EnvironmentObject private var daemon: DaemonModel
    @ObservedObject private var l10n = L10n.shared

    /// The slider position = strictness 0..1 (StrictnessMapping maps it into the request).
    @State private var strictness = 0.30
    @State private var didInitStrictness = false
    /// PUT debounce: the slider moves often, config.json should not.
    @State private var putTask: Task<Void, Never>?

    /// The «Who to trust» choice lives locally (AppStorage): it is a viewing mode,
    /// not a daemon setting — config.json has no field for it.
    @AppStorage("searchTrust") private var trust = "all"

    // the «Create your own benchmark» dialog
    @State private var showCustomDialog = false
    @State private var customQuestion = ""
    @State private var customFile = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(Section.search.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)

                strictnessCard
                trustCard
                benchmarkCard

                Text(L("search.footer"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.bmemWindow)
        .navigationTitle(Section.search.title)
        // UI-9: the duplicated title plate is hidden (commented out per the
        // acceptance requirement), UI-8 strings go through the catalog.
        // .toolbar {
        //     ToolbarItem(placement: .principal) {
        //         Text(Section.search.title).font(.system(size: 13)).foregroundStyle(.primary)
        //     }
        // }
        .task {
            await daemon.refreshBenchmark()
            // Take the slider position from the config as soon as it appears (pollLoop
            // outruns onAppear — wait with a short loop).
            for _ in 0..<40 where !didInitStrictness {
                if let cfg = daemon.config {
                    strictness = cfg.min_similarity ?? 0.30
                    didInitStrictness = true
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .alert(L("search.custom.title"), isPresented: $showCustomDialog) {
            TextField(L("search.custom.q"), text: $customQuestion)
            TextField(L("search.custom.file"), text: $customFile)
            Button(L("search.custom.add")) {
                let q = customQuestion.trimmingCharacters(in: .whitespaces)
                let f = customFile.trimmingCharacters(in: .whitespaces)
                if !q.isEmpty && !f.isEmpty {
                    Task { await daemon.addCustomBenchmark(question: q, expectedFile: f) }
                }
                customQuestion = ""
                customFile = ""
            }
            Button(L("common.cancel"), role: .cancel) { customQuestion = ""; customFile = "" }
        } message: {
            Text(L("search.custom.msg"))
        }
    }

    // MARK: - Strictness

    private var strictnessCard: some View {
        Card {
            HStack {
                Text(L("search.strict"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(L("search.strict.more"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemSecondary)
            }
            Text(L("search.strict.hint"))
                .font(.system(size: 12))
                .foregroundStyle(Color.bmemSecondary)
            Slider(value: $strictness, in: 0...1)
                .tint(Color.bmemAccent)
                .onChange(of: strictness) { _, newValue in
                    putTask?.cancel()
                    putTask = Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        await daemon.putConfig(["min_similarity":
                            StrictnessMapping.queryValue(slider: newValue)])
                    }
                }
        }
    }

    // MARK: - Who to trust

    private var trustCard: some View {
        Card {
            Text(L("search.trust"))
                .font(.system(size: 14, weight: .semibold))
            Text(L("search.trust.note"))
                .font(.system(size: 12))
                .foregroundStyle(Color.bmemSecondary)
            SegmentedRow(options: [("all", L("trust.all")),
                                   ("human", L("trust.human")),
                                   ("agent", L("trust.agent"))],
                          selection: trust) { trust = $0 }
        }
    }

    // MARK: - Accuracy benchmark

    private var benchmarkCard: some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("search.benchmark"))
                        .font(.system(size: 14, weight: .semibold))
                    if let b = daemon.benchmark, b.total > 0 {
                        Text(Lf("search.benchmark.line", b.hit, b.total))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.bmemSecondary)
                    } else if let err = daemon.benchmarkError {
                        Text(Lf("search.benchmark.err", err))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.bmemOrange)
                    } else {
                        Text(L("search.benchmark.loading"))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.bmemSecondary)
                    }
                }
                Spacer(minLength: 0)
                Button(L("search.benchmark.add")) { showCustomDialog = true }
                    .buttonStyle(CompactButtonStyle())
                    .disabled(daemon.benchmarkBusy)
            }
            if let b = daemon.benchmark, b.total > 0 {
                progressBar(Double(b.hit) / Double(max(b.total, 1)))
            }
            if let custom = daemon.benchmark?.custom, custom.total > 0 {
                HStack(spacing: 10) {
                    Text(Lf("search.benchmark.custom", custom.hit, custom.total))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bmemSecondary)
                    Button(L("search.benchmark.recheck")) {
                        Task { await daemon.recheckCustomBenchmark() }
                    }
                    .buttonStyle(CompactButtonStyle())
                    .disabled(daemon.benchmarkBusy)
                    Spacer(minLength: 0)
                }
            }
            if let err = daemon.benchmarkError, daemon.benchmark != nil {
                Text(Lf("search.benchmark.lastop", err))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bmemOrange)
            }
        }
    }

    /// A progress bar as in the reference: a thin capsule, green fill.
    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Color.bmemGreen)
                    .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}
