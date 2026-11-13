import CryptoKit
import Foundation
import Network
import Security

/// What the Mac that asks to pair does with the other Mac.
enum PairingRole: String, Codable, Sendable {
    /// Registers the Mac's runners and changes its settings.
    case manager
    /// Shows the Mac's status and changes its settings from another Mac's window.
    case dashboard
}

/// A pairing between two Macs, kept by both of them: a managing host and a Mac it manages, or a dashboard and a host
/// it shows.
struct HostPairing: Codable, Equatable, Identifiable, Sendable {
    /// Names this pairing on each connection as the TLS pre-shared key identity.
    let id: UUID
    /// The other Mac's computer name when they paired.
    let name: String
    let key: Data

    var symmetricKey: SymmetricKey { SymmetricKey(data: key) }
}

/// A request from a managing host or a dashboard to a Mac paired with it.
enum HostLinkRequest: Codable, Sendable {
    case settings(HostSettingsRequest)
    case github(GitHubRequest)
    case macs(ManagedMacsRequest)
    case runners(RunnerRequest)
    case operation(RemoteOperationRequest)
    /// Asks the Mac to forget this pairing.
    case unpair
}

/// Reads or changes a paired Mac's settings. The Mac answers with its settings afterwards.
enum HostSettingsRequest: Codable, Sendable {
    case read
    case configurePool(PoolSettingsDraft.Changes)
    case saveStorage(directory: String)
    /// Saves the Xcode that the Mac's jobs use when they name none, as its `Contents/Developer` directory, or `nil`
    /// for the Xcode that `xcode-select` names.
    case saveXcode(developerDirectory: String?)
    /// Restarts the Mac's host after it answered, which applies a saved storage folder and stops its runner services
    /// meanwhile.
    case restart
}

/// Reads or changes a host's GitHub sign-in and repository selection. The host answers with its GitHub state
/// afterwards, and keeps its tokens.
enum GitHubRequest: Codable, Sendable {
    case read
    /// Starts the device flow on the host. A later read carries the code for the person to enter on GitHub's page.
    case signIn
    case cancelSignIn
    case signOut
    case reloadRepositories
    /// Saves the selection. The host then registers and removes runners, which later reads report.
    case applySelection(Set<Int>)
}

/// Reads or changes a managed Mac's runner folders. The managing host compares them with GitHub and makes the GitHub
/// requests, so only registration tokens leave it. A Mac refuses these requests from a dashboard.
enum RunnerRequest: Codable, Sendable {
    case hostName
    case inventory
    case prepareArchive(GitHubRunnerDownload)
    case install(RunnerProvisioner.InstallationRequest)
    case markUnregistering(runner: String, repositoryID: Int)
    case markRemoved(runner: String)
}

/// Runs a build or test of a dashboard's checkout on a host. One operation's messages share a connection: the
/// dashboard sends `start`, the checkout's files, and `filesEnd`, and the host answers with `RemoteOperationEvent`s
/// until `finished`. The host stops the operation when the connection ends before the dashboard sends `received`.
enum RemoteOperationRequest: Codable, Sendable {
    case start(RemoteOperation)
    /// A piece of a tar archive of the checkout's files.
    case files(Data)
    case filesEnd
    /// The dashboard has every event up to `finished`.
    case received
}

/// A build or test that a dashboard asks a host to run.
struct RemoteOperation: Codable, Equatable, Sendable {
    /// Identifies the checkout's repository on the dashboard. The host unpacks every checkout of a repository at the
    /// same path, because compiler cache entries name source files by their paths.
    let repository: String
    /// The name of the folder that the host unpacks the checkout into.
    let name: String
    /// The directory inside the checkout that the operation runs in, or an empty string for the checkout itself.
    let directory: String
    /// The `xcode-runner` command: `build`, `build-for-testing`, or `test`.
    let action: String
    /// The command's options, without those that name the host's own folders.
    let arguments: [String]
}

enum RemoteOperationEvent: Codable, Sendable {
    /// The host takes the operation. Its output names the checkout and the operation's output by these folders.
    case accepted(checkoutDirectory: String, outputDirectory: String)
    case output(Data)
    /// The command's exit status. The log and result bundle follow.
    case exited(Int32)
    /// A piece of a tar archive of the log and result bundle.
    case results(Data)
    case finished
}

enum HostLinkReply: Codable, Sendable {
    case settings(HostSettingsReport)
    case github(GitHubReport)
    case macs(ManagedMacsReport)
    case operation(RemoteOperationEvent)
    case hostName(String)
    case runners(RunnerInventory)
    case archive(URL)
    /// The Mac finished a change to its runner folders.
    case completed
    case unpaired
    case refused(String)
}

/// A message from the Mac that asks to pair to a Mac that waits to pair.
enum PairingRequest: Codable, Sendable {
    /// Commits to the asking Mac's public key, and sends the other values that the code covers, before the Mac sends
    /// its key. Someone in between then has to choose every value before learning the one that decides the code.
    ///
    /// - Parameter version: The version of the asking Mac's messages. A Mac from before messages carried a version
    ///   sends none.
    case begin(commitment: Data, pairingID: UUID, requesterName: String, role: PairingRole, version: Int?)
    case reveal(publicKey: Data)
    /// Sent after the person confirms on the asking Mac that both Macs show the same code.
    case confirm(Data)
}

enum PairingReply: Codable, Sendable {
    /// `hostID` stays the same when the Mac pairs again, so the asking Mac replaces its earlier pairing.
    case publicKey(Data, name: String, hostID: UUID)
    /// Sent after the person allows the pairing on the Mac and the Mac saves it.
    case paired(Data)
    case refused(String)
}

/// Why a Mac refused to pair, as the asking Mac shows it.
struct PairingRefusal: Error {
    let message: String

    init(_ message: String) { self.message = message }
}

/// How another Mac's app version compares with the version of the Mac that connects to it or lists it.
enum VersionMismatch: String, Codable, Equatable, Sendable {
    /// The other Mac runs an older version.
    case older
    /// The other Mac runs a newer version.
    case newer

    /// - Parameter version: The other Mac's version of the messages, which differs from `own`.
    init(theirs version: Int, own: Int) { self = version < own ? .older : .newer }
}

/// A request or a reply with the version of its sender's messages, so that Macs that run different versions can say
/// so instead of failing to read each other.
struct Versioned<Payload: Codable & Sendable>: Codable, Sendable {
    let version: Int
    /// `nil` when the payload could not be read, as when another version sent it.
    let payload: Payload?

    init(_ payload: Payload, version: Int) {
        self.version = version
        self.payload = payload
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Versions from before messages carried one sent the payload alone.
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        payload = try? container.decode(Payload.self, forKey: .payload)
    }
}

enum HostLinkError: LocalizedError, Equatable {
    /// The TLS handshake failed: the other Mac does not have this key.
    case rejected
    /// The other Mac runs another version of the app, and the Macs cannot read each other's messages.
    case incompatible(VersionMismatch)
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
        case .incompatible(.older): "The Mac runs an older version of XcodeHomeRunner. Update it."
        case .incompatible(.newer): "The Mac runs a newer version of XcodeHomeRunner. Update this version to match it."
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
        /// The Mac that asked to pair.
        case requester
        case mac
    }

    /// The pre-shared key for the paired Macs' connections. It never crosses the network.
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
        commitment: Data, requesterKey: Data, macKey: Data, pairingID: UUID, requesterName: String, role: PairingRole,
        macName: String, hostID: UUID
    ) -> Data {
        let parts = [
            commitment, requesterKey, macKey, Data(pairingID.uuidString.utf8), Data(requesterName.utf8),
            Data(role.rawValue.utf8), Data(macName.utf8), Data(hostID.uuidString.utf8),
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

/// Connections between paired Macs: a managing host and the Macs it manages, or a dashboard and the hosts it shows.
enum HostLink {
    /// Advertised by a Mac for each Mac paired with it. The app's `NSBonjourServices` lists both types.
    static let managementService = "_xcrunner._tcp"
    /// Advertised by a Mac while it waits to pair.
    static let pairingService = "_xcrunner-pair._tcp"
    /// The management service's TXT record key holding the pairing ID, so each paired Mac finds its own service.
    static let pairingKeyName = "pairing"
    /// The pairing service's TXT record key holding the role that the Mac waits for, so a Mac lists only the Macs
    /// it can pair with.
    static let roleKeyName = "role"
    /// The TXT record key of both services holding `version`, so a Mac can tell before it connects.
    static let versionKeyName = "version"
    /// The version of the messages that paired Macs exchange. Raise it with every change after which a Mac running
    /// the previous version could not read a request, a reply, or a report.
    static let version = 4
    /// A connection whose key the other Mac rejects keeps waiting instead of failing, so requests stop after this long.
    static let requestTimeout = Duration.seconds(10)

    typealias ServerProtocol = Coder<Versioned<HostLinkReply>, Versioned<HostLinkRequest>, NetworkJSONCoder>
    typealias ClientProtocol = Coder<Versioned<HostLinkRequest>, Versioned<HostLinkReply>, NetworkJSONCoder>
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
            Coder(sending: Versioned<HostLinkRequest>.self, receiving: Versioned<HostLinkReply>.self, using: .json) { TCP() }
        }
    }

    static func serverParameters(key: SymmetricKey, identity: String) -> NWParametersBuilder<ServerProtocol> {
        .parameters(initialParameters: tlsParameters(key: key, identity: identity)) {
            Coder(sending: Versioned<HostLinkReply>.self, receiving: Versioned<HostLinkRequest>.self, using: .json) { TCP() }
        }
    }

    /// Sends one request and returns the reply, failing promptly when the Mac rejects the key or cannot be reached.
    ///
    /// Throws `HostLinkError.incompatible` when the Mac answers with another version.
    ///
    /// - Parameters:
    ///   - version: The version of this Mac's messages.
    ///   - timeout: How long the Mac has to reply.
    static func send(
        _ request: HostLinkRequest, to endpoint: NWEndpoint, key: SymmetricKey, identity: String,
        version: Int = version, timeout: Duration = requestTimeout
    ) async throws -> HostLinkReply {
        try await exchange(with: endpoint, key: key, identity: identity, version: version) { exchange in
            try await within(timeout) {
                try await exchange.send(request)
                return try await exchange.receive()
            }
        }
    }

    /// One connection's messages, for a request that takes several.
    struct Exchange: Sendable {
        let send: @Sendable (HostLinkRequest) async throws -> Void
        /// Throws `HostLinkError.incompatible` when the Mac answers with another version.
        let receive: @Sendable () async throws -> HostLinkReply
    }

    /// Connects to a paired Mac for `body`, failing promptly when the Mac rejects the key or cannot be reached. The
    /// connection ends when `body` returns.
    ///
    /// - Parameter version: The version of this Mac's messages.
    static func exchange<Result: Sendable>(
        with endpoint: NWEndpoint, key: SymmetricKey, identity: String, version: Int = version,
        _ body: @escaping @Sendable (Exchange) async throws -> Result
    ) async throws -> Result {
        let connection = NetworkConnection(to: endpoint, using: clientParameters(key: key, identity: identity))
        return try await whileConnected(connection) { connection in
            try await body(Exchange(
                send: { try await connection.send(Versioned($0, version: version)) },
                receive: {
                    let reply = try await connection.receive().content
                    guard reply.version == version else {
                        throw HostLinkError.incompatible(VersionMismatch(theirs: reply.version, own: version))
                    }
                    guard let payload = reply.payload else { throw HostLinkError.unexpectedReply }
                    return payload
                }
            ))
        }
    }

    /// Accepts connections that use `key` until the task is cancelled.
    ///
    /// A request from a Mac that runs another version is answered with this Mac's version and not handled.
    ///
    /// - Parameters:
    ///   - version: The version of this Mac's messages.
    ///   - ready: Called with the listening port once the listener is ready.
    ///   - connected: Called with the version of each request's sender.
    ///   - handle: Answers a request through `reply`, and can act after replying. `next` waits for the following
    ///     message of a request that takes several, and throws when the connection ends.
    static func listen(
        key: SymmetricKey, identity: String, version: Int = version, advertising service: BonjourListenerProvider?,
        ready: @escaping @Sendable (NWEndpoint.Port) async -> Void,
        connected: @escaping @Sendable (_ version: Int) async -> Void,
        handle: @escaping @Sendable (
            HostLinkRequest, _ reply: @escaping @Sendable (HostLinkReply) async throws -> Void,
            _ next: @escaping @Sendable () async throws -> HostLinkRequest
        ) async throws -> Void
    ) async throws {
        let listener = try NetworkListener(for: service, using: serverParameters(key: key, identity: identity))
        listener.onStateUpdate { listener, state in
            guard case .ready = state, let port = listener.port else { return }
            Task { await ready(port) }
        }
        try await listener.run { connection in
            do {
                // Receiving throws when the connection ends.
                while true {
                    let message = try await connection.receive().content
                    await connected(message.version)
                    guard message.version == version, let request = message.payload else {
                        // The sender reads this reply's version and not its payload.
                        try await connection.send(Versioned(HostLinkReply.refused("The Macs run different versions."), version: version))
                        continue
                    }
                    try await handle(request, { try await connection.send(Versioned($0, version: version)) }) {
                        let following = try await connection.receive().content
                        guard following.version == version, let request = following.payload else {
                            throw HostLinkError.unexpectedReply
                        }
                        return request
                    }
                }
            } catch {
                // One connection's failure, such as a wrong key, does not stop the listener.
            }
        }
    }

    /// Pairs with the Mac at `endpoint`.
    ///
    /// - Parameters:
    ///   - role: What this Mac does with the Mac. The Mac refuses a role that it does not wait for.
    ///   - confirm: Shows the code and returns once the person confirms that the Mac shows the same code.
    /// - Returns: The pairing and the Mac's host ID.
    static func requestPairing(
        at endpoint: NWEndpoint, pairingID: UUID, requesterName: String, role: PairingRole, version: Int = version,
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
                try await connection.send(PairingRequest.begin(
                    commitment: commitment, pairingID: pairingID, requesterName: requesterName, role: role, version: version
                ))
                return try await connection.receive().content
            }
            guard case .publicKey(let macKey, let macName, let hostID) = reply else { throw unexpected(reply) }
            try await connection.send(PairingRequest.reveal(publicKey: publicKey))
            let agreement = try PairingAgreement(
                privateKey: privateKey, peerPublicKey: macKey,
                transcript: PairingAgreement.transcript(
                    commitment: commitment, requesterKey: publicKey, macKey: macKey, pairingID: pairingID,
                    requesterName: requesterName, role: role, macName: macName, hostID: hostID
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
                    try await connection.send(PairingRequest.confirm(agreement.proof(from: .requester)))
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
    ///   - role: What the Mac that pairs may do. A request for another role is refused.
    ///   - begin: Takes a request before this Mac sends its key, or throws to refuse it.
    ///   - allow: Shows the code for a request and returns once the person allows the pairing on this Mac.
    ///   - save: Keeps the pairing once the person allowed it and the asking Mac confirmed the code.
    ///   - ended: Called after each connection, once the asking Mac got the reply.
    static func acceptPairing(
        name: String, hostID: UUID, role: PairingRole, version: Int = version, advertising service: BonjourListenerProvider?,
        ready: @escaping @Sendable (NWEndpoint.Port) async -> Void,
        begin: @escaping @Sendable (_ connection: UUID, _ requesterName: String) async throws -> Void,
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
                on: connection, name: name, hostID: hostID, role: role, version: version,
                begin: { requesterName in try await begin(id, requesterName) },
                allow: { code in try await allow(id, code) },
                save: save
            )
            await ended(id)
        }
    }

    /// Answers one Mac's request to pair, with the pairing's proof or the reason this Mac refused.
    private static func answerPairing(
        on connection: NetworkConnection<PairingServerProtocol>, name: String, hostID: UUID, role: PairingRole, version: Int,
        begin: @escaping @Sendable (_ requesterName: String) async throws -> Void,
        allow: @escaping @Sendable (_ code: String) async throws -> Void,
        save: @escaping @Sendable (HostPairing) async throws -> Void
    ) async {
        let notVerified = PairingRefusal("\(name) could not verify the pairing request.")
        enum Step { case allowed, confirmed }
        // Cancelling a pending receive closes the connection, so the reply is sent before the group cancels it.
        await withThrowingTaskGroup(of: Step.self) { group in
            do {
                guard case .begin(let commitment, let pairingID, let requesterName, let requestedRole, let requesterVersion)
                        = try await within(requestTimeout, { try await connection.receive().content }) else {
                    throw notVerified
                }
                // Macs that run different versions cannot read each other's messages after they pair.
                guard requesterVersion == version else {
                    throw PairingRefusal(VersionMismatch(theirs: requesterVersion ?? 0, own: version) == .older
                        ? "\(name) runs a newer version of XcodeHomeRunner. Update \(requesterName) to pair."
                        : "\(name) runs an older version of XcodeHomeRunner. Update it to pair.")
                }
                // The person opened this Mac to one role, so a request cannot choose another.
                guard requestedRole == role else {
                    throw PairingRefusal(role == .manager
                        ? "\(name) is waiting for a managing Mac, not a dashboard."
                        : "\(name) is waiting for a dashboard, not a managing Mac.")
                }
                // Each key this Mac sends gives someone in between another chance at a matching code, so a request is
                // taken before the key is sent.
                try await begin(requesterName)
                let privateKey = Curve25519.KeyAgreement.PrivateKey()
                let publicKey = privateKey.publicKey.rawRepresentation
                try await connection.send(PairingReply.publicKey(publicKey, name: name, hostID: hostID))
                guard case .reveal(let requesterKey) = try await within(requestTimeout, { try await connection.receive().content }),
                      Data(SHA256.hash(data: requesterKey)) == commitment else {
                    throw notVerified
                }
                let agreement = try PairingAgreement(
                    privateKey: privateKey, peerPublicKey: requesterKey,
                    transcript: PairingAgreement.transcript(
                        commitment: commitment, requesterKey: requesterKey, macKey: publicKey, pairingID: pairingID,
                        requesterName: requesterName, role: role, macName: name, hostID: hostID
                    )
                )
                // Pairing needs both the person's permission here and the asking Mac's confirmation, in either order.
                group.addTask {
                    try await allow(agreement.code)
                    return .allowed
                }
                group.addTask {
                    guard case .confirm(let proof) = try await connection.receive().content,
                          agreement.isValid(proof, from: .requester) else { throw notVerified }
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
                        // The asking Mac sends nothing more, so a message or the end of the connection means that
                        // it stopped pairing while the person here decides.
                        group.addTask {
                            _ = try await connection.receive()
                            throw notVerified
                        }
                    }
                }
                try await save(HostPairing(id: pairingID, name: requesterName, key: agreement.key))
                try? await connection.send(PairingReply.paired(agreement.proof(from: .mac)))
            } catch let refusal as PairingRefusal {
                try? await connection.send(PairingReply.refused(refusal.message))
            } catch {
                // The asking Mac left, or this Mac stopped waiting to pair.
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
            group.addTask {
                // A send or receive can throw the connection's failure before its state reports it.
                do { return try await body(connection) } catch let error as NWError { throw HostLinkError(error) }
            }
            group.addTask {
                for await error in failures.stream { throw HostLinkError(error) }
                throw CancellationError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Runs `operation`, and throws `HostLinkError.timedOut` when it takes longer than `timeout`.
    static func within<Result: Sendable>(
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
