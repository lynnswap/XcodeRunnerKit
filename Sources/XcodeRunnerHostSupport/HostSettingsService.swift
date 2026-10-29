import Foundation
import XcodeRunnerKit

package struct HostSettingsError: Error, LocalizedError, Sendable {
    package let message: String
    package init(_ message: String) { self.message = message }
    package var errorDescription: String? { message }
}

package enum HostSettingValue: Codable, Sendable, Equatable {
    case null, bool(Bool), integer(Int), string(String), array([HostSettingValue]), object([String: HostSettingValue])

    package init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Int.self) { self = .integer(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([HostSettingValue].self) { self = .array(result) }
        else { self = .object(try value.decode([String: HostSettingValue].self)) }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

package enum HostSettingsScope: String, Codable, Sendable, CaseIterable {
    case pool, buildService, storage, githubRepositories
}

package struct HostSettingChoice: Codable, Sendable {
    package let value: HostSettingValue
    package let label: String
}

package struct HostSetting: Codable, Sendable {
    package let key: String
    package let scope: HostSettingsScope
    package let type: String
    package var value: HostSettingValue?
    package var activeValue: HostSettingValue?
    package let defaultValue: HostSettingValue
    package let constraints: [String: HostSettingValue]
    package var choices: [HostSettingChoice]
    package let appliesAt: String
    package var editable: Bool = true
    package var unavailableReason: String?
    package var readError: String?
}

package struct HostSettingsSnapshot: Codable, Sendable {
    package let settings: [HostSetting]
}

package struct HostSettingsUpdateResult: Codable, Sendable {
    package let scope: HostSettingsScope
    package let state: String
    package let settings: [HostSetting]
    package let errors: [String]
}

package enum HostSettingsUpdate: Codable, Sendable {
    case pool(maximumConcurrentJobs: Int?, simulatorRetention: HostExecutionPool.SimulatorRetention?)
    case buildService(path: String?)
    case storage(directory: String)
    case githubRepositories(selectedRepositoryIDs: [Int])

    package var scope: HostSettingsScope {
        switch self {
        case .pool: .pool
        case .buildService: .buildService
        case .storage: .storage
        case .githubRepositories: .githubRepositories
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case scope, maximumConcurrentJobs, simulatorRetention, path, directory, selectedRepositoryIDs
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let scope = try container.decode(HostSettingsScope.self, forKey: .scope)
        let fields: Set<String>
        switch scope {
        case .pool:
            fields = ["scope", "maximumConcurrentJobs", "simulatorRetention"]
            let maximum = try container.decodeIfPresent(Int.self, forKey: .maximumConcurrentJobs)
            let retention = try container.decodeIfPresent(HostExecutionPool.SimulatorRetention.self, forKey: .simulatorRetention)
            for key in [CodingKeys.maximumConcurrentJobs, .simulatorRetention] where container.contains(key) {
                if try container.decodeNil(forKey: key) { throw HostSettingsError("\(key.rawValue) cannot be null.") }
            }
            if container.contains(.simulatorRetention) {
                let nested = try container.superDecoder(forKey: .simulatorRetention).container(keyedBy: AnyKey.self)
                let allowed = retention == .forever ? Set(["mode"]) : Set(["mode", "minutes"])
                if let unknown = nested.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
                    throw HostSettingsError("Unknown simulatorRetention field: \(unknown.stringValue)")
                }
            }
            self = .pool(maximumConcurrentJobs: maximum, simulatorRetention: retention)
        case .buildService:
            fields = ["scope", "path"]
            guard container.contains(.path) else { throw HostSettingsError("Specify path, or null to clear the build service override.") }
            let path = try container.decodeIfPresent(String.self, forKey: .path)
            self = .buildService(path: path)
        case .storage:
            fields = ["scope", "directory"]
            let directory = try container.decode(String.self, forKey: .directory)
            self = .storage(directory: directory)
        case .githubRepositories:
            fields = ["scope", "selectedRepositoryIDs"]
            let ids = try container.decode([Int].self, forKey: .selectedRepositoryIDs)
            self = .githubRepositories(selectedRepositoryIDs: ids)
        }
        let allKeys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        if let unknown = allKeys.first(where: { !fields.contains($0) }) {
            throw HostSettingsError("Unknown field for \(scope.rawValue): \(unknown)")
        }
        try validate()
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scope, forKey: .scope)
        switch self {
        case .pool(let maximum, let retention):
            try container.encodeIfPresent(maximum, forKey: .maximumConcurrentJobs)
            try container.encodeIfPresent(retention, forKey: .simulatorRetention)
        case .buildService(let path):
            try container.encode(path, forKey: .path)
        case .storage(let directory): try container.encode(directory, forKey: .directory)
        case .githubRepositories(let ids): try container.encode(ids, forKey: .selectedRepositoryIDs)
        }
    }

    private static func requireAbsolutePath(_ value: String) throws {
        guard value.hasPrefix("/") else { throw HostSettingsError("Enter an absolute filesystem path.") }
    }

    func validate() throws {
        switch self {
        case .pool(let maximum, let retention):
            guard maximum != nil || retention != nil else { throw HostSettingsError("Specify a pool setting to update.") }
            if let maximum, maximum <= 0 { throw HostSettingsError("maximumConcurrentJobs must be a positive integer.") }
            if let retention, case .idleTimeout(let minutes) = retention, minutes <= 0 {
                throw HostSettingsError("Simulator idle timeout minutes must be positive.")
            }
        case .buildService(let path): if let path { try Self.requireAbsolutePath(path) }
        case .storage(let directory): try Self.requireAbsolutePath(directory)
        case .githubRepositories(let ids):
            guard ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else {
                throw HostSettingsError("Repository IDs must be distinct positive integers.")
            }
        }
    }
}

package struct HostSettingsService: Sendable {
    package let installation: HostInstallation
    package let pool: HostExecutionPool
    private let githubRequest: @Sendable (HostSettingsBridgeRequest) async throws -> HostSettingsBridgeResponse

    package init(
        installation: HostInstallation = .init(), pool: HostExecutionPool? = nil,
        githubRequest: @escaping @Sendable (HostSettingsBridgeRequest) async throws -> HostSettingsBridgeResponse = HostSettingsBridge.request
    ) {
        self.installation = installation
        self.pool = pool ?? HostExecutionPool(directory: installation.poolDirectory)
        self.githubRequest = githubRequest
    }

    @discardableResult
    package func configurePool(
        maximumConcurrentJobs: Int? = nil, simulatorRetention: HostExecutionPool.SimulatorRetention? = nil
    ) async throws -> HostExecutionPool.Configuration {
        try await pool.configure(maximumConcurrentJobs: maximumConcurrentJobs, simulatorRetention: simulatorRetention)
    }

    package func requestStorageDirectory(_ directory: URL) async throws -> URL {
        try await installation.requestStorageDirectory(directory)
    }

    @discardableResult
    package func saveBuildServiceExecutableURL(_ url: URL?) throws -> URL? {
        try installation.saveBuildServiceExecutableURL(url)
    }

    package func getSettings(scope: HostSettingsScope? = nil) async -> HostSettingsSnapshot {
        var settings: [HostSetting] = []
        if scope == nil || scope == .pool { settings += poolSettings() }
        if scope == nil || scope == .buildService { settings.append(buildServiceSetting()) }
        if scope == nil || scope == .storage { settings.append(storageSetting()) }
        if scope == nil || scope == .githubRepositories { settings.append(await repositorySetting()) }
        return HostSettingsSnapshot(settings: settings)
    }

    package func update(_ update: HostSettingsUpdate) async throws -> HostSettingsUpdateResult {
        try update.validate()
        var errors: [String] = []
        switch update {
        case .pool(let maximum, let retention):
            do { try await configurePool(maximumConcurrentJobs: maximum, simulatorRetention: retention) }
            catch let failure as HostExecutionPool.ConfigurationCleanupFailure { errors.append(failure.localizedDescription) }
        case .buildService(let path):
            try saveBuildServiceExecutableURL(path.map { URL(filePath: $0) })
        case .storage(let directory):
            _ = try await requestStorageDirectory(URL(filePath: directory))
        case .githubRepositories(let ids):
            let response = try await githubRequest(.updateRepositories(ids))
            if let error = response.error { throw HostSettingsError(error) }
            if let error = response.synchronizationError { errors.append(error) }
            guard let saved = response.settings else { throw HostSettingsError("The host did not return the saved repository selection.") }
            return HostSettingsUpdateResult(
                scope: update.scope, state: errors.isEmpty ? "saved" : "savedWithErrors",
                settings: [Self.repositorySetting(saved, editable: true)], errors: errors
            )
        }
        let snapshot = await getSettings(scope: update.scope)
        errors += snapshot.settings.compactMap(\.readError)
        return HostSettingsUpdateResult(scope: update.scope, state: errors.isEmpty ? "saved" : "savedWithErrors", settings: snapshot.settings, errors: errors)
    }

    private func poolSettings() -> [HostSetting] {
        var maximum = HostSetting(
            key: "maximumConcurrentJobs", scope: .pool, type: "integer", defaultValue: .integer(HostInstallation.defaultMaximumConcurrentJobs),
            constraints: ["minimum": .integer(1)], choices: [], appliesAt: "nextSlotAcquisition"
        )
        var retention = HostSetting(
            key: "simulatorRetention", scope: .pool, type: "object", defaultValue: .object(["mode": .string("idleTimeout"), "minutes": .integer(20)]),
            constraints: ["minutesMinimum": .integer(1)],
            choices: [.init(value: .object(["mode": .string("forever")]), label: "Keep idle Simulators indefinitely"), .init(value: .object(["mode": .string("idleTimeout"), "minutes": .integer(20)]), label: "Delete after idle minutes")],
            appliesAt: "nextSimulatorLeaseOrMaintenance"
        )
        do {
            let configuration = try pool.configuration()
            maximum.value = configuration.map { .integer($0.maximumConcurrentJobs) } ?? .null
            retention.value = try configuration.map { try Self.value($0.simulatorRetention) } ?? .null
            if let configuration, case .idleTimeout(let minutes) = configuration.simulatorRetention {
                retention.choices[1] = .init(value: .object(["mode": .string("idleTimeout"), "minutes": .integer(minutes)]), label: "Delete after idle minutes")
            }
        } catch { maximum.readError = error.localizedDescription; retention.readError = error.localizedDescription }
        return [maximum, retention]
    }

    private func buildServiceSetting() -> HostSetting {
        var item = HostSetting(
            key: "path", scope: .buildService, type: "stringOrNull", defaultValue: .null,
            constraints: ["absolutePath": .bool(true)], choices: [], appliesAt: "nextCLIInvocation"
        )
        do { item.value = try installation.buildServiceExecutableURL().map { .string($0.path(percentEncoded: false)) } ?? .null }
        catch { item.readError = error.localizedDescription }
        return item
    }

    private func storageSetting() -> HostSetting {
        var item = HostSetting(
            key: "directory", scope: .storage, type: "string", defaultValue: .string(installation.hostRoot.appending(path: "Storage").path(percentEncoded: false)),
            constraints: ["absolutePath": .bool(true), "existingDirectory": .bool(true)], choices: [], appliesAt: "nextHostLaunchAfterMigration"
        )
        do {
            let active = try installation.storage()?.directory
            item.activeValue = active.map { .string($0.path(percentEncoded: false)) } ?? .null
            item.value = try (installation.requestedStorageDirectory() ?? active).map { .string($0.path(percentEncoded: false)) } ?? .null
        } catch { item.readError = error.localizedDescription }
        return item
    }

    private func repositorySetting() async -> HostSetting {
        do {
            let response = try await githubRequest(.getRepositories)
            if let error = response.error { throw HostSettingsError(error) }
            guard let settings = response.settings else { throw HostSettingsError("The host did not return repository settings.") }
            return Self.repositorySetting(settings, editable: true)
        } catch {
            var item = Self.repositorySetting(.init(selectedRepositoryIDs: [], choices: []), editable: false)
            item.unavailableReason = error.localizedDescription
            struct Saved: Decodable { let repositories: [HostSettingsRepository] }
            do {
                let repositories: [HostSettingsRepository]
                do { repositories = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: installation.hostRoot.appending(path: "github-host.json"))).repositories }
                catch let failure as CocoaError where failure.code == .fileReadNoSuchFile { repositories = [] }
                item.value = .array(repositories.map { .integer($0.id) })
                item.choices = repositories.map { .init(value: .integer($0.id), label: $0.fullName) }
            } catch { item.value = nil; item.readError = error.localizedDescription }
            return item
        }
    }

    private static func repositorySetting(_ settings: HostGitHubRepositorySettings, editable: Bool) -> HostSetting {
        HostSetting(
            key: "selectedRepositoryIDs", scope: .githubRepositories, type: "integerArray", value: .array(settings.selectedRepositoryIDs.map { .integer($0) }),
            defaultValue: .array([]), constraints: ["uniqueItems": .bool(true)],
            choices: settings.choices.map { .init(value: .integer($0.id), label: $0.fullName) }, appliesAt: "repositorySynchronization", editable: editable
        )
    }

    private static func value(_ value: some Encodable) throws -> HostSettingValue {
        try JSONDecoder().decode(HostSettingValue.self, from: JSONEncoder().encode(value))
    }
}
