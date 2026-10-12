import AppKit
import Foundation
import Observation
import SwiftUI
import XcodeRunnerKit

enum RunnerServiceState: String, Sendable {
    case starting = "Starting"
    case running = "Running"
    case stopped = "Stopped"
    case failed = "Needs attention"
    case individualService = "Individual service"
}

struct RunnerSettingsRow: Identifiable, Sendable {
    let directory: URL
    let name: String
    let state: RunnerServiceState
    let workDirectory: URL?
    let log: URL?
    let configurationError: String?

    var id: URL { directory }

    static func read(directory: URL, state: RunnerServiceState, logsDirectory: URL) -> Self {
        struct Registration: Decodable {
            var agentName: String?
            var workFolder: String?
        }
        let log = state == .individualService ? nil : logsDirectory.appending(path: directory.lastPathComponent + ".log")
        do {
            let registration = try JSONDecoder().decode(
                Registration.self, from: Data(contentsOf: directory.appending(path: ".runner"))
            )
            return Self(
                directory: directory, name: registration.agentName ?? directory.lastPathComponent, state: state,
                workDirectory: registration.workFolder.map {
                    let installation = URL(filePath: directory.path(percentEncoded: false), directoryHint: .isDirectory)
                    return URL(filePath: $0, directoryHint: .isDirectory, relativeTo: installation).standardizedFileURL
                },
                log: log, configurationError: nil
            )
        } catch {
            return Self(
                directory: directory, name: directory.lastPathComponent, state: state, workDirectory: nil,
                log: log,
                configurationError: "Could not read this runner’s settings: \(error.localizedDescription)"
            )
        }
    }
}

@MainActor @Observable
final class HostSettingsModel {
    let hostRoot: URL
    let runnersRoot: URL
    let logsDirectory: URL
    let pool: HostExecutionPool
    var hostState = "Starting"
    var runners: [RunnerSettingsRow] = []
    var runnerScanError: String?
    private(set) var poolStatus: HostExecutionPool.Status?
    private(set) var poolError: String?
    private(set) var saveError: String?
    private(set) var isSaving = false
    private(set) var hasLoadedPoolStatus = false
    var capacityInput = "4"

    init(hostRoot: URL, runnersRoot: URL, logsDirectory: URL) throws {
        self.hostRoot = hostRoot
        self.runnersRoot = runnersRoot
        self.logsDirectory = logsDirectory
        // Reading status does not initialize the pool. Only Apply or a job can do that.
        self.pool = try HostExecutionPool(directory: hostRoot.appending(path: "Pool"), initialCapacity: 4)
    }

    var compilationCache: URL { hostRoot.appending(path: "CompilationCache") }

    var admissionMessage: String {
        if !hasLoadedPoolStatus { return "Checking the execution pool…" }
        if poolError != nil { return "The execution pool is unavailable." }
        guard let poolStatus else { return "Set a limit to configure the shared execution pool." }
        if poolStatus.activeJobCount > poolStatus.maximumConcurrentJobs {
            return "Existing jobs will finish. New jobs wait until the running count falls below the limit."
        }
        if poolStatus.activeJobCount == poolStatus.maximumConcurrentJobs {
            return "New jobs wait for an available slot."
        }
        return "New jobs can start while slots are available."
    }

    func refreshPoolStatus() async {
        do {
            let previousInput = poolStatus.map { String($0.maximumConcurrentJobs) } ?? "4"
            let status = try await pool.status()
            poolStatus = status
            poolError = nil
            hasLoadedPoolStatus = true
            if capacityInput == previousInput, let status {
                capacityInput = String(status.maximumConcurrentJobs)
            }
        } catch is CancellationError {
            return
        } catch {
            poolStatus = nil
            poolError = "Could not read the execution pool: \(error.localizedDescription)"
            hasLoadedPoolStatus = true
        }
    }

    func applyCapacity() async {
        guard hasLoadedPoolStatus, !isSaving else { return }
        guard let capacity = Int(capacityInput), capacity > 0 else {
            saveError = "Enter a positive whole number."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await pool.updateMaximumConcurrentJobs(to: capacity)
            saveError = nil
            await refreshPoolStatus()
        } catch {
            saveError = "Could not save the execution limit: \(error.localizedDescription)"
        }
    }
}

@MainActor
struct HostSettingsView: View {
    @Bindable var model: HostSettingsModel

    var body: some View {
        ScrollView {
            Form {
                Section("Execution Pool") {
                    LabeledContent("Running jobs") {
                        Text(model.poolStatus.map { String($0.activeJobCount) } ?? unavailablePoolValue)
                            .monospacedDigit()
                    }
                    LabeledContent("Waiting jobs (High)") {
                        Text(model.poolStatus.map { String($0.waitingJobCounts.high) } ?? unavailablePoolValue)
                            .monospacedDigit()
                    }
                    LabeledContent("Waiting jobs (Medium)") {
                        Text(model.poolStatus.map { String($0.waitingJobCounts.medium) } ?? unavailablePoolValue)
                            .monospacedDigit()
                    }
                    LabeledContent("Waiting jobs (Low)") {
                        Text(model.poolStatus.map { String($0.waitingJobCounts.low) } ?? unavailablePoolValue)
                            .monospacedDigit()
                    }
                    LabeledContent("Current limit") {
                        Text(model.poolStatus.map { String($0.maximumConcurrentJobs) } ?? unavailablePoolValue)
                            .monospacedDigit()
                    }
                    HStack {
                        TextField("Maximum concurrent jobs", text: $model.capacityInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("execution-limit")
                        Button(model.isSaving ? "Applying…" : "Apply") {
                            Task { await model.applyCapacity() }
                        }
                        .disabled(!model.hasLoadedPoolStatus || model.isSaving || model.hostState == "Stopping")
                        .accessibilityIdentifier("apply-execution-limit")
                    }
                    Text(model.admissionMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let error = model.poolError { errorMessage(error) }
                    if let error = model.saveError { errorMessage(error) }
                }
                Section("Runner Services") {
                    LabeledContent("Host", value: model.hostState)
                    if model.runners.isEmpty {
                        Text("No runners have opted in to this host.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.runners) { runner in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(runner.name).font(.headline)
                                Spacer()
                                Text(runner.state.rawValue).foregroundStyle(.secondary)
                            }
                            directoryRow("Installation", url: runner.directory)
                            if let work = runner.workDirectory { directoryRow("Work directory", url: work) }
                            else { LabeledContent("Work directory", value: "Not available") }
                            if let log = runner.log { directoryRow("Service log", url: log) }
                            else { LabeledContent("Service log", value: "Managed by individual service") }
                            if runner.state == .individualService {
                                Text("This runner uses its individual service. The host does not start another service for it.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            if let error = runner.configurationError { errorMessage(error) }
                        }
                        .padding(.vertical, 4)
                    }
                    Text("Service status describes local processes. Check GitHub for connection and job status.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let error = model.runnerScanError { errorMessage(error) }
                }
                Section("Storage") {
                    directoryRow("Host data", url: model.hostRoot)
                    directoryRow("Execution pool", url: model.pool.directory)
                    directoryRow("Compilation cache", url: model.compilationCache)
                    directoryRow("Runner installations", url: model.runnersRoot)
                    directoryRow("Runner logs", url: model.logsDirectory)
                    Text("Storage locations come from the host installation and runner registrations.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 540, minHeight: 420)
    }

    private var unavailablePoolValue: String {
        if !model.hasLoadedPoolStatus { return "Checking…" }
        return model.poolError == nil ? "Not configured" : "Unavailable"
    }

    private func directoryRow(_ title: String, url: URL) -> some View {
        let physical = url.resolvingSymlinksInPath()
        return LabeledContent(title) {
            HStack {
                Text(physical.path(percentEncoded: false))
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([physical])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
                .accessibilityLabel("Show \(title) in Finder")
            }
        }
    }

    private func errorMessage(_ message: String) -> some View {
        Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled)
    }
}
