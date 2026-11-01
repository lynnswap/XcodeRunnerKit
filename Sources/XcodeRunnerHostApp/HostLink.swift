import CryptoKit
import Foundation
import Network
import Security

/// A pairing between a managing host and a Mac it manages, kept by both of them.
struct HostPairing: Codable, Equatable, Identifiable, Sendable {
    /// Names this pairing on each connection as the TLS pre-shared key identity.
    let id: UUID
    /// The other Mac's computer name when they paired.
    let name: String
    let key: Data

    var symmetricKey: SymmetricKey { SymmetricKey(data: key) }
}

/// A request from a managing host to a Mac it manages.
enum HostLinkRequest: Codable, Sendable {
    case settings(HostSettingsRequest)
    /// Asks the Mac to forget this pairing.
    case unpair
}

/// Reads or changes a managed Mac's settings. The Mac answers with its settings afterwards.
enum HostSettingsRequest: Codable, Sendable {
    case read
    case configurePool(PoolSettingsDraft.Changes)
    case saveStorage(directory: String)
}

enum HostLinkReply: Codable, Sendable {
    case settings(HostSettingsReport)
    case unpaired
    case refused(String)
}

/// A message from a managing host to a Mac that waits to pair.
enum PairingRequest: Codable, Sendable {
    /// Commits to the host's public key, and sends the other values that the code covers, before the Mac sends its
    /// key. Someone in between then has to choose every value before learning the one that decides the code.
    case begin(commitment: Data, pairingID: UUID, managerName: String)
    case reveal(publicKey: Data)
    /// Sent after the person confirms on the managing host that both Macs show the same code.
    case confirm(Data)
}

enum PairingReply: Codable, Sendable {
    /// `hostID` stays the same when the Mac pairs again, so the managing host replaces its earlier pairing.
    case publicKey(Data, name: String, hostID: UUID)
    /// Sent after the person allows the pairing on the Mac and the Mac saves it.
    case paired(Data)
    case refused(String)
}

/// Why a Mac refused to pair, as the managing host shows it.
struct PairingRefusal: Error {
    let message: String

    init(_ message: String) { self.message = message }
}

enum HostLinkError: LocalizedError, Equatable {
    /// The TLS handshake failed: the other Mac does not have this key.
    case rejected
    case unreachable(String)
    case timedOut
    case refused(String)
    case unexpectedReply

    init(_ error: NWError) {
        if case .tls = error { self = .rejected } else { self = .unreachable(error.localizedDescription) }
    }

    var errorDescription: String? {
        switch self {
        case .rejected: "The Mac did not accept the key."
        case .unreachable(let message): "The Mac could not be reached: \(message)"
        case .timedOut: "The Mac did not answer."
        case .refused(let message): message
        case .unexpectedReply: "The Mac sent an unexpected reply."
        }
    }
}

/// What both Macs derive from the key agreement while pairing.
struct PairingAgreement: Sendable {
    enum Role: String {
        case manager
        case mac
    }

    /// The pre-shared key for management connections. It never crosses the network.
    let key: Data
    /// Six digits that both Macs show. Anyone else taking part in the exchange changes the code on at least one Mac.
    let code: String
    private let confirmationKey: SymmetricKey

    init(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data, transcript: Data) throws {
        let secret = try privateKey.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        )
        let salt = Data(SHA256.hash(data: transcript))
        func derive(_ purpose: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: salt, sharedInfo: Data("XcodeHomeRunner \(purpose)".utf8), outputByteCount: 32
            )
        }
        key = derive("management key").withUnsafeBytes { Data($0) }
        confirmationKey = derive("pairing confirmation")
        let digest = SHA256.hash(data: Data("XcodeHomeRunner pairing code".utf8) + transcript)
        code = String(format: "%06d", digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000)
    }

    /// Every value exchanged while pairing, so that a changed value changes the code.
    static func transcript(
        commitment: Data, managerKey: Data, macKey: Data, pairingID: UUID, managerName: String, macName: String, hostID: UUID
    ) -> Data {
        let parts = [
            commitment, managerKey, macKey, Data(pairingID.uuidString.utf8), Data(managerName.utf8), Data(macName.utf8),
            Data(hostID.uuidString.utf8),
        ]
        return parts.reduce(into: Data()) { transcript, part in
            withUnsafeBytes(of: UInt32(part.count).bigEndian) { transcript.append(contentsOf: $0) }
            transcript.append(part)
        }
    }

    /// Shows the other Mac that this Mac derived the same keys.
    func proof(from role: Role) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(role.rawValue.utf8), using: confirmationKey))
    }

    func isValid(_ proof: Data, from role: Role) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data(role.rawValue.utf8), using: confirmationKey)
    }
}

/// Connections between a managing host and the Macs it manages.
enum HostLink {
    /// Advertised by a Mac while another host manages it. The app's `NSBonjourServices` lists both types.
    static let managementService = "_xcrunner._tcp"
    /// Advertised by a Mac while it waits to pair.
    static let pairingService = "_xcrunner-pair._tcp"
    /// The management service's TXT record key holding the pairing ID, so the managing host finds its own Macs.
    static let pairingKeyName = "pairing"
    /// A connection whose key the other Mac rejects keeps waiting instead of failing, so requests stop after this long.
    static let requestTimeout = Duration.seconds(10)

    typealias ServerProtocol = Coder<HostLinkReply, HostLinkRequest, NetworkJSONCoder>
    typealias ClientProtocol = Coder<HostLinkRequest, HostLinkReply, NetworkJSONCoder>
    typealias PairingServerProtocol = Coder<PairingReply, PairingRequest, NetworkJSONCoder>

    /// TLS with the pairing key as the pre-shared key. The ephemeral ECDH exchange keeps recorded connections secret
    /// if the key leaks later. Network.framework negotiates external pre-shared keys only up to TLS 1.2.
    static func tlsParameters(key: SymmetricKey, identity: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, keyData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(
            options, tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!
        )
        return NWParameters(tls: tls)
    }

    static func clientParameters(key: SymmetricKey, identity: String) -> NWParametersBuilder<ClientProtocol> {
        .parameters(initialParameters: tlsParameters(key: key, identity: identity)) {
            Coder(sending: HostLinkRequest.self, receiving: HostLinkReply.self, using: .json) { TCP() }
        }
    }

    static func serverParameters(key: SymmetricKey, identity: String) -> NWParametersBuilder<ServerProtocol> {
        .parameters(initialParameters: tlsParameters(key: key, identity: identity)) {
            Coder(sending: HostLinkReply.self, receiving: HostLinkRequest.self, using: .json) { TCP() }
        }
    }

    /// Sends one request and returns the reply, failing promptly when the Mac rejects the key or cannot be reached.
    ///
    /// - Parameter timeout: How long the Mac has to reply.
    static func send(
        _ request: HostLinkRequest, to endpoint: NWEndpoint, key: SymmetricKey, identity: String,
        timeout: Duration = requestTimeout
    ) async throws -> HostLinkReply {
        let connection = NetworkConnection(to: endpoint, using: clientParameters(key: key, identity: identity))
        return try await whileConnected(connection) { connection in
            try await within(timeout) {
                try await connection.send(request)
                return try await connection.receive().content
            }
        }
    }

    /// Accepts connections that use `key` until the task is cancelled.
    ///
    /// - Parameters:
    ///   - ready: Called with the listening port once the listener is ready.
    ///   - handle: Answers a request through `reply`, and can act after replying.
    static func listen(
        key: SymmetricKey, identity: String, advertising service: BonjourListenerProvider?,
        ready: @escaping @Sendable (NWEndpoint.Port) async -> Void,
        handle: @escaping @Sendable (HostLinkRequest, _ reply: (HostLinkReply) async throws -> Void) async throws -> Void
    ) async throws {
        let listener = try NetworkListener(for: service, using: serverParameters(key: key, identity: identity))
        listener.onStateUpdate { listener, state in
            guard case .ready = state, let port = listener.port else { return }
            Task { await ready(port) }
        }
        try await listener.run { connection in
            do {
                for try await message in connection.messages {
                    try await handle(message.content) { try await connection.send($0) }
                }
            } catch {
                // One connection's failure, such as a wrong key, does not stop the listener.
            }
        }
    }

    /// Pairs with the Mac at `endpoint`.
    ///
    /// - Parameter confirm: Shows the code and returns once the person confirms that the Mac shows the same code.
    /// - Returns: The pairing and the Mac's host ID.
    static func requestPairing(
        at endpoint: NWEndpoint, pairingID: UUID, managerName: String,
        confirm: @escaping @Sendable (_ macName: String, _ code: String) async throws -> Void
    ) async throws -> (pairing: HostPairing, hostID: UUID) {
        let connection = NetworkConnection(to: endpoint) {
            Coder(sending: PairingRequest.self, receiving: PairingReply.self, using: .json) { TCP() }
        }
        return try await whileConnected(connection) { connection in
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let publicKey = privateKey.publicKey.rawRepresentation
            let commitment = Data(SHA256.hash(data: publicKey))
            let reply = try await within(requestTimeout) {
                try await connection.send(PairingRequest.begin(commitment: commitment, pairingID: pairingID, managerName: managerName))
                return try await connection.receive().content
            }
            guard case .publicKey(let macKey, let macName, let hostID) = reply else { throw unexpected(reply) }
            try await connection.send(PairingRequest.reveal(publicKey: publicKey))
            let agreement = try PairingAgreement(
                privateKey: privateKey, peerPublicKey: macKey,
                transcript: PairingAgreement.transcript(
                    commitment: commitment, managerKey: publicKey, macKey: macKey, pairingID: pairingID,
                    managerName: managerName, macName: macName, hostID: hostID
                )
            )
            // The Mac can refuse while the person compares the codes here, and the person can allow the pairing on the
            // Mac first.
            let outcome = try await withThrowingTaskGroup(of: PairingReply?.self) { group in
                group.addTask {
                    try await within(.seconds(HostManagement.pairingDuration)) { try await connection.receive().content }
                }
                group.addTask {
                    try await confirm(macName, agreement.code)
                    try await connection.send(PairingRequest.confirm(agreement.proof(from: .manager)))
                    return nil
                }
                defer { group.cancelAll() }
                var reply: PairingReply?
                var isConfirmed = false
                while let result = try await group.next() {
                    if let result { reply = result } else { isConfirmed = true }
                    switch reply {
                    case nil: continue
                    // Whoever answered can prove the key, so only the person's confirmation here lets the pairing finish.
                    case .paired? where !isConfirmed: continue
                    case let reply?: return reply
                    }
                }
                throw HostLinkError.unexpectedReply
            }
            guard case .paired(let proof) = outcome else { throw unexpected(outcome) }
            guard agreement.isValid(proof, from: .mac) else { throw HostLinkError.unexpectedReply }
            return (HostPairing(id: pairingID, name: macName, key: agreement.key), hostID)
        }
    }

    /// Accepts pairing requests until the task is cancelled.
    ///
    /// - Parameters:
    ///   - begin: Takes a managing host's request before this Mac sends its key, or throws to refuse it.
    ///   - allow: Shows the code for a request and returns once the person allows the pairing on this Mac.
    ///   - save: Keeps the pairing once the person allowed it and the managing host confirmed the code.
    ///   - ended: Called after each connection, once the managing host got the reply.
    static func acceptPairing(
        name: String, hostID: UUID, advertising service: BonjourListenerProvider?,
        ready: @escaping @Sendable (NWEndpoint.Port) async -> Void,
        begin: @escaping @Sendable (_ connection: UUID, _ managerName: String) async throws -> Void,
        allow: @escaping @Sendable (_ connection: UUID, _ code: String) async throws -> Void,
        save: @escaping @Sendable (HostPairing) async throws -> Void,
        ended: @escaping @Sendable (_ connection: UUID) async -> Void
    ) async throws {
        let listener = try NetworkListener(for: service) {
            Coder(sending: PairingReply.self, receiving: PairingRequest.self, using: .json) { TCP() }
        }
        listener.onStateUpdate { listener, state in
            guard case .ready = state, let port = listener.port else { return }
            Task { await ready(port) }
        }
        try await listener.run { connection in
            let id = UUID()
            await answerPairing(
                on: connection, name: name, hostID: hostID,
                begin: { managerName in try await begin(id, managerName) },
                allow: { code in try await allow(id, code) },
                save: save
            )
            await ended(id)
        }
    }

    /// Answers one managing host's request to pair, with the pairing's proof or the reason this Mac refused.
    private static func answerPairing(
        on connection: NetworkConnection<PairingServerProtocol>, name: String, hostID: UUID,
        begin: @escaping @Sendable (_ managerName: String) async throws -> Void,
        allow: @escaping @Sendable (_ code: String) async throws -> Void,
        save: @escaping @Sendable (HostPairing) async throws -> Void
    ) async {
        let notVerified = PairingRefusal("\(name) could not verify the pairing request.")
        enum Step { case allowed, confirmed }
        // Cancelling a pending receive closes the connection, so the reply is sent before the group cancels it.
        await withThrowingTaskGroup(of: Step.self) { group in
            do {
                guard case .begin(let commitment, let pairingID, let managerName) = try await within(requestTimeout, {
                    try await connection.receive().content
                }) else {
                    throw notVerified
                }
                // Each key this Mac sends gives someone in between another chance at a matching code, so a request is
                // taken before the key is sent.
                try await begin(managerName)
                let privateKey = Curve25519.KeyAgreement.PrivateKey()
                let publicKey = privateKey.publicKey.rawRepresentation
                try await connection.send(PairingReply.publicKey(publicKey, name: name, hostID: hostID))
                guard case .reveal(let managerKey) = try await within(requestTimeout, { try await connection.receive().content }),
                      Data(SHA256.hash(data: managerKey)) == commitment else {
                    throw notVerified
                }
                let agreement = try PairingAgreement(
                    privateKey: privateKey, peerPublicKey: managerKey,
                    transcript: PairingAgreement.transcript(
                        commitment: commitment, managerKey: managerKey, macKey: publicKey, pairingID: pairingID,
                        managerName: managerName, macName: name, hostID: hostID
                    )
                )
                // Pairing needs both the person's permission here and the managing host's confirmation, in either order.
                group.addTask {
                    try await allow(agreement.code)
                    return .allowed
                }
                group.addTask {
                    guard case .confirm(let proof) = try await connection.receive().content,
                          agreement.isValid(proof, from: .manager) else { throw notVerified }
                    return .confirmed
                }
                var isAllowed = false
                var isConfirmed = false
                // Unlike `waitForAll()`, this stops at the first failure, such as the person refusing.
                while !(isAllowed && isConfirmed), let step = try await group.next() {
                    switch step {
                    case .allowed: isAllowed = true
                    case .confirmed:
                        isConfirmed = true
                        // The managing host sends nothing more, so a message or the end of the connection means that
                        // it stopped pairing while the person here decides.
                        group.addTask {
                            _ = try await connection.receive()
                            throw notVerified
                        }
                    }
                }
                try await save(HostPairing(id: pairingID, name: managerName, key: agreement.key))
                try? await connection.send(PairingReply.paired(agreement.proof(from: .mac)))
            } catch let refusal as PairingRefusal {
                try? await connection.send(PairingReply.refused(refusal.message))
            } catch {
                // The managing host left, or this Mac stopped waiting to pair.
            }
            group.cancelAll()
        }
    }

    private static func unexpected(_ reply: PairingReply) -> HostLinkError {
        if case .refused(let message) = reply { return .refused(message) }
        return .unexpectedReply
    }

    /// Runs `body`, failing as soon as the connection fails or waits, as it does when the other Mac rejects the key.
    private static func whileConnected<ApplicationProtocol: SendableMetatype, Result: Sendable>(
        _ connection: NetworkConnection<ApplicationProtocol>,
        _ body: @escaping @Sendable (NetworkConnection<ApplicationProtocol>) async throws -> Result
    ) async throws -> Result {
        let failures = AsyncStream<NWError>.makeStream()
        connection.onStateUpdate { _, state in
            switch state {
            case .waiting(let error), .failed(let error): failures.continuation.yield(error)
            default: break
            }
        }
        return try await withThrowingTaskGroup { group in
            group.addTask { try await body(connection) }
            group.addTask {
                for await error in failures.stream { throw HostLinkError(error) }
                throw CancellationError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func within<Result: Sendable>(
        _ timeout: Duration, _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HostLinkError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
