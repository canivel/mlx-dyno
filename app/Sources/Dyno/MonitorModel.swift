import Foundation
import DynoKit
import Observation
import SwiftUI

/// Owns the sampler and publishes snapshots to the UI.
///
/// Sampling costs tens of milliseconds and touches IOKit, so it runs on a
/// background queue; only the finished snapshot crosses back to the main actor.
@Observable
@MainActor
final class MonitorModel {
    /// One instance for the whole app. The SwiftUI scene and the AppKit window
    /// controller both need it, and the delegate is constructed before any view
    /// exists, so passing it down from a view does not work.
    static let shared = MonitorModel()

    private(set) var system = SystemInfo()
    private(set) var snapshot = Snapshot()
    private(set) var history = History()
    private(set) var isAvailable = false
    private(set) var startupError: String?

    // -- local model serving -------------------------------------------------
    private(set) var localModels: [LocalModel] = []
    private(set) var serverState: ServerController.State = .stopped
    private(set) var runtime: Runtime.Kind?
    var selectedModel: LocalModel?

    // -- catalog -------------------------------------------------------------
    private(set) var catalog: [CatalogModel] = []
    private(set) var catalogError: String?
    private(set) var isSearching = false
    private(set) var downloads: [String: DownloadManager.Progress] = [:]
    var searchText: String = ""
    /// Set to ask the window to switch tabs; the window clears it once handled.
    /// Chat needs to send you to Run when nothing is loaded.
    var requestedTab: MainWindow.Tab?
    var catalogSort: ModelCatalog.Sort = .popular {
        didSet { runSearch(query: searchText) }
    }

    /// Repository ids already on disk, so the catalog can say so.
    var downloadedRepositories: Set<String> {
        Set(localModels.map(\.name))
    }

    var modelFolders: [String] {
        didSet {
            UserDefaults.standard.set(modelFolders, forKey: Defaults.modelFolders)
            rescanModels()
        }
    }

    var interval: TimeInterval {
        didSet {
            UserDefaults.standard.set(interval, forKey: Defaults.interval)
            restartTimer()
        }
    }

    var menuBarContent: MenuBarContent {
        didSet {
            UserDefaults.standard.set(menuBarContent.rawValue, forKey: Defaults.menuBarContent)
        }
    }

    @ObservationIgnored private var sampler: Sampler?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(
        label: "com.canivel.dyno.sampler", qos: .utility
    )
    @ObservationIgnored private var isSampling = false
    @ObservationIgnored private var lastModelRefresh: Date = .distantPast
    /// Model discovery does loopback HTTP, so it runs far less often than the
    /// counter reads.
    @ObservationIgnored private let modelRefreshInterval: TimeInterval = 3.0
    @ObservationIgnored private let server = ServerController()
    @ObservationIgnored private let downloader = DownloadManager()
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init() {
        Defaults.register()
        let defaults = UserDefaults.standard
        interval = max(0.25, defaults.double(forKey: Defaults.interval))
        menuBarContent = MenuBarContent(
            rawValue: defaults.string(forKey: Defaults.menuBarContent) ?? ""
        ) ?? .gpuAndPower

        modelFolders = defaults.stringArray(forKey: Defaults.modelFolders) ?? []

        let override = defaults.double(forKey: Defaults.peakBandwidth)
        let sampler = Sampler(peakBandwidthOverride: override > 0 ? override : nil)
        self.sampler = sampler
        system = sampler.system
        isAvailable = sampler.isAvailable
        if !sampler.isAvailable {
            startupError = "Could not read the system telemetry counters. "
                + "GPU Monitor needs an Apple Silicon Mac."
        }
        runtime = Runtime.current
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.serverState = state }
        }
        downloader.onChange = { [weak self] progress in
            Task { @MainActor in
                self?.downloads = progress
                // A finished download is a new model in the library.
                if progress.values.contains(where: { $0.isFinished && $0.error == nil }) {
                    self?.rescanModels()
                }
            }
        }
        rescanModels()
        loadCatalog()
        start()
    }

    // MARK: - Catalog

    func loadCatalog() {
        runSearch(query: searchText)
    }

    /// Debounced: typing should not fire a request per keystroke.
    func searchCatalog(_ query: String) {
        searchText = query
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            runSearch(query: query)
        }
    }

    private func runSearch(query: String) {
        isSearching = true
        catalogError = nil
        Task { @MainActor in
            do {
                let results = try await ModelCatalog.search(query, sort: self.catalogSort)
                self.catalog = results
                self.isSearching = false
                await self.fillSizes(for: results)
            } catch {
                self.catalog = []
                self.catalogError = error.localizedDescription
                self.isSearching = false
            }
        }
    }

    /// Sizes need a request each, so they arrive after the list rather than
    /// holding it up. Bounded concurrency keeps this polite to the hub.
    private func fillSizes(for models: [CatalogModel]) async {
        let ids = models.prefix(30).map(\.id)
        var sizes: [String: Int64] = [:]
        await withTaskGroup(of: (String, Int64?).self) { group in
            var running = 0
            var iterator = ids.makeIterator()
            func addNext() {
                guard let id = iterator.next() else { return }
                running += 1
                group.addTask { (id, await ModelCatalog.size(of: id)) }
            }
            for _ in 0..<min(6, ids.count) { addNext() }
            while let (id, size) = await group.next() {
                running -= 1
                if let size { sizes[id] = size }
                addNext()
            }
        }
        // Sorting by date surfaces a lot of half-finished uploads: a repo
        // claiming to be a 36B model with 20 MB of files has no weights in it
        // yet. Once a size is known, drop anything too small to be a model.
        let minimumUsableBytes: Int64 = 100 * 1024 * 1024
        catalog = catalog.compactMap { model in
            var model = model
            if let size = sizes[model.id] {
                guard size >= minimumUsableBytes else { return nil }
                model.sizeBytes = size
            }
            return model
        }
    }

    func download(_ model: CatalogModel) { downloader.download(model.id) }
    func cancelDownload(_ model: CatalogModel) { downloader.cancel(model.id) }
    func dismissDownload(_ repository: String) { downloader.clear(repository) }

    // MARK: - Serving models

    func rescanModels() {
        let folders = modelFolders
        Task.detached(priority: .utility) {
            let found = ModelLibrary.scan(extraPaths: folders)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.localModels = found
                if self.selectedModel == nil || !found.contains(where: { $0.id == self.selectedModel?.id }) {
                    self.selectedModel = found.first
                }
            }
        }
    }

    func addModelFolder(_ path: String) {
        guard !modelFolders.contains(path) else { return }
        modelFolders.append(path)
    }

    func startSelectedModel() {
        guard let model = selectedModel else { return }
        let port = UInt16(UserDefaults.standard.integer(forKey: Defaults.serverPort))
        server.start(model: model, port: port == 0 ? 8971 : port)
    }

    func stopServer() {
        server.stop()
    }

    /// Called when the app quits so a model server is never left orphaned.
    func shutdown() {
        server.stop()
        stop()
    }

    var serverLog: String { server.log }

    func start() {
        guard isAvailable else { return }
        restartTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common keeps sampling alive while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        guard let sampler, !isSampling else { return }
        isSampling = true
        queue.async { [weak self] in
            let snapshot = sampler.sample()
            Task { @MainActor in
                guard let self else { return }
                self.snapshot = snapshot
                self.history.push(snapshot)
                self.isSampling = false
            }
        }

        if Date().timeIntervalSince(lastModelRefresh) >= modelRefreshInterval {
            lastModelRefresh = Date()
            let processes = snapshot.processes
            Task.detached(priority: .utility) {
                await sampler.refreshModels(processes: processes)
            }
        }
    }

    func resetHistory() {
        history.reset()
    }
}
