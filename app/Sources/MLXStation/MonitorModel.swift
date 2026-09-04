import Foundation
import MLXStationKit
import Observation
import SwiftUI

/// Owns the sampler and publishes snapshots to the UI.
///
/// Sampling costs tens of milliseconds and touches IOKit, so it runs on a
/// background queue; only the finished snapshot crosses back to the main actor.
@Observable
@MainActor
final class MonitorModel {
    private(set) var system = SystemInfo()
    private(set) var snapshot = Snapshot()
    private(set) var history = History()
    private(set) var isAvailable = false
    private(set) var startupError: String?

    // -- local model serving -------------------------------------------------
    private(set) var localModels: [LocalModel] = []
    private(set) var serverState: ServerController.State = .stopped
    private(set) var mlxservePath: String?
    var selectedModel: LocalModel?

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
        label: "com.gpumonitor.sampler", qos: .utility
    )
    @ObservationIgnored private var isSampling = false
    @ObservationIgnored private var lastModelRefresh: Date = .distantPast
    /// Model discovery does loopback HTTP, so it runs far less often than the
    /// counter reads.
    @ObservationIgnored private let modelRefreshInterval: TimeInterval = 3.0
    @ObservationIgnored private let server = ServerController()

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
        let configured = defaults.string(forKey: Defaults.mlxservePath)
        mlxservePath = ServerController.findExecutable(
            configured: (configured?.isEmpty == false) ? configured : nil
        )
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.serverState = state }
        }
        rescanModels()
        start()
    }

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
        guard let executable = mlxservePath, let model = selectedModel else { return }
        let port = UInt16(UserDefaults.standard.integer(forKey: Defaults.serverPort))
        server.start(executable: executable, model: model, port: port == 0 ? 8971 : port)
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
