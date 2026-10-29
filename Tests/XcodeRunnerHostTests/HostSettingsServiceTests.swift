import Foundation
import Testing
import XcodeRunnerHostSupport
import XcodeRunnerKit

@Suite(.timeLimit(.minutes(1)))
struct HostSettingsServiceTests {
    private func service(at root: URL) -> HostSettingsService {
        HostSettingsService(installation: HostInstallation(homeDirectory: root), githubRequest: { _ in
            HostSettingsBridgeResponse(settings: .init(selectedRepositoryIDs: [], choices: []))
        })
    }

    @Test func catalogReadDoesNotInitializeAndDistinguishesCorruptSettings() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(at: root)
        let empty = await service.getSettings(scope: .pool)
        #expect(empty.settings.count == 2)
        #expect(empty.settings.allSatisfy { $0.value == .null && $0.readError == nil })
        #expect(!FileManager.default.fileExists(atPath: service.pool.directory.path()))
        try FileManager.default.createDirectory(at: service.pool.directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: service.pool.directory.appending(path: "configuration.json"))

        let corrupt = await service.getSettings(scope: .pool)
        #expect(corrupt.settings.allSatisfy { $0.value == nil && $0.readError != nil })
    }

    @Test func partialPoolPatchPreservesOtherSettingsAndRejectsInvalidPatchBeforeSaving() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(at: root)
        _ = try await service.update(.pool(maximumConcurrentJobs: 4, simulatorRetention: .forever))
        let result = try await service.update(.pool(maximumConcurrentJobs: 3, simulatorRetention: nil))
        #expect(result.state == "saved")
        #expect(try service.pool.configuration() == .init(maximumConcurrentJobs: 3, simulatorRetention: .forever))

        await #expect(throws: (any Error).self) {
            try await service.update(.pool(maximumConcurrentJobs: 8, simulatorRetention: .idleTimeout(minutes: 0)))
        }
        #expect(try service.pool.configuration()?.maximumConcurrentJobs == 3)
    }

    @Test func synchronizationFailureReportsSavedRepositorySelection() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = HostSettingsService(installation: HostInstallation(homeDirectory: root), githubRequest: { _ in
            HostSettingsBridgeResponse(settings: .init(selectedRepositoryIDs: [7], choices: [.init(id: 7, fullName: "owner/Project")]), synchronizationError: "GitHub is unavailable.")
        })
        let result = try await service.update(.githubRepositories(selectedRepositoryIDs: [7]))
        #expect(result.state == "savedWithErrors")
        #expect(result.errors == ["GitHub is unavailable."])
        #expect(result.settings.first?.value == .array([.integer(7)]))
    }

    @Test func storagePatchKeepsActiveStorageUntilNextLaunch() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(at: root)
        let active = try service.installation.initializeStorage()
        let target = root.appending(path: "NextStorage")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let result = try await service.update(.storage(directory: target.path()))
        #expect(result.state == "saved")
        #expect(try service.installation.storage()?.directory == active.directory)
        let item = try #require(result.settings.first)
        #expect(item.appliesAt == "nextHostLaunchAfterMigration")
        #expect(item.value != item.activeValue)
    }

    @Test func buildServiceNullClearsOverrideWithoutChangingPool() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = service(at: root)
        _ = try await service.update(.buildService(path: "/Applications/Custom/SWBBuildService"))
        #expect(try service.installation.buildServiceExecutableURL()?.path() == "/Applications/Custom/SWBBuildService")
        _ = try await service.update(.buildService(path: nil))
        #expect(try service.installation.buildServiceExecutableURL() == nil)
        #expect(try service.pool.configuration() == nil)
    }

    @Test func unavailableAppReturnsSavedRepositorySelectionWithoutAllowingEdits() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = HostInstallation(homeDirectory: root)
        try FileManager.default.createDirectory(at: installation.hostRoot, withIntermediateDirectories: true)
        try Data(#"{"repositories":[{"id":7,"full_name":"owner/Project"}]}"#.utf8)
            .write(to: installation.hostRoot.appending(path: "github-host.json"))
        let service = HostSettingsService(installation: installation, githubRequest: { _ in throw HostSettingsError("Host unavailable.") })
        let snapshot = await service.getSettings(scope: .githubRepositories)
        let item = try #require(snapshot.settings.first)
        #expect(item.value == .array([.integer(7)]))
        #expect(!item.editable)
        #expect(item.unavailableReason == "Host unavailable.")
        #expect(item.readError == nil)
    }

    @Test(arguments: [
        #"{"scope":"pool","maximumConcurrentJobs":3,"path":"/elsewhere"}"#,
        #"{"scope":"pool","simulatorRetention":{"mode":"forever","minutes":20}}"#,
        #"{"scope":"pool","maximumConcurrentJobs":null}"#,
        #"{"scope":"buildService"}"#,
        #"{"scope":"githubRepositories","selectedRepositoryIDs":[7,7]}"#,
    ])
    func rejectsFieldsThatDoNotBelongToTypedPatch(_ json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(HostSettingsUpdate.self, from: Data(json.utf8)) }
    }
}
