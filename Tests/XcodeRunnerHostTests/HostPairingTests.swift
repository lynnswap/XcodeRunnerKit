import CryptoKit
import Foundation
import Network
import Security
import Testing
@testable import XcodeRunnerHostApp

@MainActor @Suite(.timeLimit(.minutes(1)))
struct HostPairingTests {
    /// Connects to a listener directly, because the tests do not advertise with Bonjour.
    private func local(_ port: NWEndpoint.Port?) throws -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: try #require(port))
    }

    private func waitToPair(_ management: HostManagement) async throws -> NWEndpoint {
        management.allowManagement()
        try await waitUntil { management.pairingWindow?.port != nil }
        return try local(management.pairingWindow?.port)
    }

    /// Pairs the Macs as a person does after seeing the same code on both.
    private func pair(_ macs: ManagedMacs, with management: HostManagement) async throws -> ManagedMac {
        let endpoint = try await waitToPair(management)
        let pairing = Task { try await macs.pair(at: endpoint) }
        try await waitUntil { macs.codeConfirmation != nil && management.pairingWindow?.request?.code != nil }
        #expect(macs.codeConfirmation?.code == management.pairingWindow?.request?.code)
        macs.confirmCode()
        management.allowPairing()
        return try await pairing.value
    }

    /// A connection that sends pairing messages without the managing host's checks.
    private func pairingConnection(to endpoint: NWEndpoint) -> NetworkConnection<Coder<PairingRequest, PairingReply, NetworkJSONCoder>> {
        NetworkConnection(to: endpoint) { Coder(sending: PairingRequest.self, receiving: PairingReply.self, using: .json) { TCP() } }
    }

    private func publicKey() -> Data { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }

    @Test func pairedMacsConnectUntilTheManagingHostRemovesTheMac() async throws {
        let managedStore = MemorySecretStore()
        let managerStore = MemorySecretStore()
        let management = HostManagement(store: managedStore, name: "Managed", advertises: false)
        let macs = ManagedMacs(store: managerStore, name: "Manager", browses: false)

        let mac = try await pair(macs, with: management)
        #expect(mac.name == "Managed")
        #expect(macs.codeConfirmation == nil)
        #expect(management.pairingWindow == nil)
        #expect(management.manager == HostPairing(id: mac.id, name: "Manager", key: mac.pairing.key))
        #expect(ManagedMacs(store: managerStore, name: "Manager", browses: false).macs == [mac])
        #expect(HostManagement(store: managedStore, name: "Managed", advertises: false).manager == management.manager)

        try await waitUntil { management.managementPort != nil }
        await macs.checkStatus(of: mac.id, at: try local(management.managementPort))
        #expect(macs.status(of: mac.id) == .online)

        await macs.remove(mac.id)
        #expect(macs.macs.isEmpty)
        #expect(macs.message == nil)
        #expect(managerStore.read() == nil)
        try await waitUntil { management.manager == nil }
        #expect(HostManagement(store: managedStore, name: "Managed", advertises: false).manager == nil)

        await management.shutDown()
        await macs.shutDown()
    }

    @Test func removalReportsAMacThatCouldNotForgetThePairing() async throws {
        let managedStore = MemorySecretStore()
        let management = HostManagement(store: managedStore, name: "Managed", advertises: false)
        let macs = ManagedMacs(store: MemorySecretStore(), name: "Manager", browses: false)
        let mac = try await pair(macs, with: management)
        try await waitUntil { management.managementPort != nil }
        await macs.checkStatus(of: mac.id, at: try local(management.managementPort))
        managedStore.failWrites(with: CocoaError(.fileWriteNoPermission))

        await macs.remove(mac.id)
        #expect(macs.macs.isEmpty)
        #expect(macs.message?.contains("Managed could not remove the pairing") == true)
        #expect(management.manager?.id == mac.id)

        await management.shutDown()
        await macs.shutDown()
    }

    @Test func refusingAPairingRequestStopsWaitingToPair() async throws {
        let management = HostManagement(store: MemorySecretStore(), name: "Managed", advertises: false)
        let macs = ManagedMacs(store: MemorySecretStore(), name: "Manager", browses: false)
        let endpoint = try await waitToPair(management)
        let pairing = Task { try await macs.pair(at: endpoint) }
        try await waitUntil { management.pairingWindow?.request?.code != nil }

        management.refusePairing()
        await #expect(throws: HostLinkError.refused("Managed did not allow the pairing.")) { try await pairing.value }
        #expect(management.pairingWindow == nil)
        #expect(management.pairingMessage == "You did not allow Manager to manage this Mac.")
        #expect(management.manager == nil)
        #expect(macs.macs.isEmpty)

        await management.shutDown()
    }

    @Test func aManagingHostThatLeavesAfterConfirmingStopsPairing() async throws {
        let management = HostManagement(store: MemorySecretStore(), name: "Managed", advertises: false)
        let macs = ManagedMacs(store: MemorySecretStore(), name: "Manager", browses: false)
        let endpoint = try await waitToPair(management)
        let pairing = Task { try await macs.pair(at: endpoint) }
        try await waitUntil { macs.codeConfirmation != nil && management.pairingWindow?.request?.code != nil }
        macs.confirmCode()
        // Lets the confirmation arrive before the managing host leaves.
        try await Task.sleep(for: .milliseconds(200))

        pairing.cancel()
        try await waitUntil { management.pairingWindow == nil }
        #expect(management.pairingMessage == "Pairing stopped because Manager did not finish pairing.")
        management.allowPairing()
        #expect(management.manager == nil)

        await management.shutDown()
    }

    @Test func aKeyThatDoesNotMatchItsCommitmentIsRefusedAndStopsPairing() async throws {
        let management = HostManagement(store: MemorySecretStore(), name: "Managed", advertises: false)
        let connection = pairingConnection(to: try await waitToPair(management))

        try await connection.send(PairingRequest.begin(
            commitment: Data(SHA256.hash(data: publicKey())), pairingID: UUID(), managerName: "Someone"
        ))
        _ = try await connection.receive()
        try await connection.send(PairingRequest.reveal(publicKey: publicKey()))
        guard case .refused(let message) = try await connection.receive().content else {
            Issue.record("The Mac did not refuse the key.")
            return
        }
        #expect(message == "Managed could not verify the pairing request.")
        try await waitUntil { management.pairingWindow == nil }
        #expect(management.pairingMessage == "Pairing stopped because Someone did not finish pairing.")

        await management.shutDown()
    }

    @Test func aMacTakesOnePairingRequestAtATime() async throws {
        let management = HostManagement(store: MemorySecretStore(), name: "Managed", advertises: false)
        let macs = ManagedMacs(store: MemorySecretStore(), name: "Manager", browses: false)
        let endpoint = try await waitToPair(management)
        let first = pairingConnection(to: endpoint)
        try await first.send(PairingRequest.begin(
            commitment: Data(SHA256.hash(data: publicKey())), pairingID: UUID(), managerName: "First"
        ))
        _ = try await first.receive()

        await #expect(throws: HostLinkError.refused("Managed is confirming another pairing.")) { try await macs.pair(at: endpoint) }
        #expect(management.pairingWindow?.request?.managerName == "First")

        await management.shutDown()
    }

    @Test func theManagingHostPairsOnlyAfterThePersonConfirmsTheCode() async throws {
        let macs = ManagedMacs(store: MemorySecretStore(), name: "Manager", browses: false)
        // Someone who answers in place of the Mac can prove the key it agreed, and says it paired right away.
        let impostor = try NetworkListener {
            Coder(sending: PairingReply.self, receiving: PairingRequest.self, using: .json) { TCP() }
        }
        let ports = AsyncStream<NWEndpoint.Port>.makeStream()
        let answered = AsyncStream<Void>.makeStream()
        impostor.onStateUpdate { listener, state in
            if case .ready = state, let port = listener.port { ports.continuation.yield(port) }
        }
        let serving = Task {
            try await impostor.run { connection in
                guard case .begin(let commitment, let pairingID, let managerName) = try await connection.receive().content else { return }
                let privateKey = Curve25519.KeyAgreement.PrivateKey()
                let publicKey = privateKey.publicKey.rawRepresentation
                let hostID = UUID()
                try await connection.send(PairingReply.publicKey(publicKey, name: "Impostor", hostID: hostID))
                guard case .reveal(let managerKey) = try await connection.receive().content else { return }
                let agreement = try PairingAgreement(
                    privateKey: privateKey, peerPublicKey: managerKey,
                    transcript: PairingAgreement.transcript(
                        commitment: commitment, managerKey: managerKey, macKey: publicKey, pairingID: pairingID,
                        managerName: managerName, macName: "Impostor", hostID: hostID
                    )
                )
                try await connection.send(PairingReply.paired(agreement.proof(from: .mac)))
                answered.continuation.yield()
                _ = try await connection.receive()
            }
        }
        var readyPorts = ports.stream.makeAsyncIterator()
        let endpoint = try local(await readyPorts.next())
        let pairing = Task { try await macs.pair(at: endpoint) }
        var answers = answered.stream.makeAsyncIterator()
        await answers.next()
        try await waitUntil { macs.codeConfirmation != nil }

        try await Task.sleep(for: .milliseconds(200))
        #expect(macs.macs.isEmpty)
        #expect(macs.codeConfirmation?.isConfirmed == false)

        pairing.cancel()
        _ = await pairing.result
        serving.cancel()
    }

    @Test func pairingTheSameMacAgainReplacesItsEarlierPairing() async throws {
        let management = HostManagement(store: MemorySecretStore(), name: "Managed", advertises: false)
        let macs = ManagedMacs(store: MemorySecretStore(), name: "Manager", browses: false)

        _ = try await pair(macs, with: management)
        management.stopManagement()
        let second = try await pair(macs, with: management)
        #expect(macs.macs == [second])
        #expect(management.manager?.id == second.id)

        await management.shutDown()
        await macs.shutDown()
    }

    @Test func managementConnectionsUseAnEphemeralKeyExchange() async throws {
        let management = HostManagement(store: MemorySecretStore(), name: "Managed", advertises: false)
        let macs = ManagedMacs(store: MemorySecretStore(), name: "Manager", browses: false)
        let mac = try await pair(macs, with: management)
        try await waitUntil { management.managementPort != nil }
        let connection = NetworkConnection(
            to: try local(management.managementPort),
            using: HostLink.clientParameters(key: mac.pairing.symmetricKey, identity: mac.id.uuidString)
        )
        try await connection.send(HostLinkRequest.status)
        _ = try await connection.receive()

        // Without ECDHE, anyone who records the connections can read them once the pairing key leaks.
        let metadata = try #require(connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)
        let suite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata)
        #expect(suite.rawValue == UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))

        await management.shutDown()
        await macs.shutDown()
    }
}
