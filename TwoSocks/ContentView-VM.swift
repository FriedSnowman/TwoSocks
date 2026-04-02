import AVFoundation
import Foundation
import SwiftUI

private let proxyPort = 4884
private let maxEndedConnections = 100
private let transferPollInterval: TimeInterval = 0.5
private let lifetimeDownloadedBytesKey = "lifetimeDownloadedBytes"
private let lifetimeUploadedBytesKey = "lifetimeUploadedBytes"

enum ProxyServerState: Equatable {
    case waitingForNetwork
    case starting
    case running
    case failed(Int32)

    var title: String {
        switch self {
        case .waitingForNetwork:
            return "Awaiting Network"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .failed:
            return "Failed"
        }
    }

    var detail: String {
        switch self {
        case .waitingForNetwork:
            return "No usable local interface detected yet."
        case .starting:
            return "Opening the SOCKS listener."
        case .running:
            return "Proxy is listening for new clients."
        case .failed(let code):
            return "Native server exited with code \(code)."
        }
    }

    var systemImage: String {
        switch self {
        case .waitingForNetwork:
            return "network.slash"
        case .starting:
            return "dot.radiowaves.left.and.right"
        case .running:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .waitingForNetwork:
            return .orange
        case .starting:
            return .blue
        case .running:
            return .green
        case .failed:
            return .red
        }
    }
}

enum ProxyConnectionProtocol: Int32 {
    case tcp = 0
    case udp = 1

    var title: String {
        switch self {
        case .tcp:
            return "TCP"
        case .udp:
            return "UDP"
        }
    }

    var systemImage: String {
        switch self {
        case .tcp:
            return "arrow.left.arrow.right.circle.fill"
        case .udp:
            return "dot.radiowaves.left.and.right"
        }
    }
}

enum ProxyConnectionState: Int32 {
    case open = 0
    case closed = 1
    case error = 2

    var title: String {
        switch self {
        case .open:
            return "Open"
        case .closed:
            return "Closed"
        case .error:
            return "Error"
        }
    }

    var tint: Color {
        switch self {
        case .open:
            return .green
        case .closed:
            return .secondary
        case .error:
            return .red
        }
    }
}

struct TrackedConnection: Identifiable {
    let id: Int64
    var title: String
    var protocolType: ProxyConnectionProtocol
    var state: ProxyConnectionState
    var updatedAt: Date
    var errorCode: Int32?
}

private final class ConnectionEventBridge {
    static weak var receiver: ContentViewVM?
}

@_cdecl("twosocks_connection_event_bridge")
func twosocks_connection_event_bridge(
    _ identifier: Int64,
    _ protocolRaw: Int32,
    _ stateRaw: Int32,
    _ host: UnsafePointer<CChar>?,
    _ port: UInt16,
    _ errorCode: Int32
) {
    let endpointHost = host.map { String(cString: $0) } ?? ""

    Task { @MainActor in
        ConnectionEventBridge.receiver?.handleConnectionEvent(
            id: identifier,
            protocolRaw: protocolRaw,
            stateRaw: stateRaw,
            host: endpointHost,
            port: port,
            errorCode: errorCode
        )
    }
}

@MainActor
final class ContentViewVM: ObservableObject {
    @Published private(set) var serverState: ProxyServerState = .starting
    @Published private(set) var endpointDisplay = "Detecting local IP"
    @Published private(set) var connections: [TrackedConnection] = []
    @Published private(set) var activeConnectionCount = 0
    @Published private(set) var totalConnectionAttempts = 0
    @Published private(set) var sessionDownloadedBytes: UInt64 = 0
    @Published private(set) var sessionUploadedBytes: UInt64 = 0
    @Published private(set) var lifetimeDownloadedBytes: UInt64 = 0
    @Published private(set) var lifetimeUploadedBytes: UInt64 = 0

    private var audioPlayer: AVAudioPlayer?
    private var hasStartedProxy = false
    private var connectionsByID: [Int64: TrackedConnection] = [:]
    private var connectionOrder: [Int64] = []
    private var transferTimer: Timer?
    private var lastNativeDownloadedBytes: UInt64 = 0
    private var lastNativeUploadedBytes: UInt64 = 0

    init() {
        loadLifetimeTransferTotals()
        ConnectionEventBridge.receiver = self
        twosocks_set_connection_event_handler(twosocks_connection_event_bridge)
        setupBackgroundAudio()
        startTransferPolling()
    }

    deinit {
        transferTimer?.invalidate()

        if ConnectionEventBridge.receiver === self {
            ConnectionEventBridge.receiver = nil
        }
    }

    var downloadedDisplay: String {
        Self.byteCountString(sessionDownloadedBytes)
    }

    var uploadedDisplay: String {
        Self.byteCountString(sessionUploadedBytes)
    }

    var lifetimeDownloadedDisplay: String {
        Self.byteCountString(lifetimeDownloadedBytes)
    }

    var lifetimeUploadedDisplay: String {
        Self.byteCountString(lifetimeUploadedBytes)
    }

    func setInterfaceUnavailable() {
        serverState = .waitingForNetwork
        endpointDisplay = "bridge100/en0 not available"
    }

    func startProxy(ipAddress: String) {
        guard !hasStartedProxy else { return }

        hasStartedProxy = true
        serverState = .starting
        endpointDisplay = "\(ipAddress):\(proxyPort)"

        Task.detached(priority: .userInitiated) { [weak self] in
            let arguments = ["microsocks", "-p", String(proxyPort)]
            let cArgs = arguments.map { strdup($0) }
            defer { cArgs.forEach { free($0) } }

            let argc = Int32(arguments.count)
            let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 1)
            defer { argv.deallocate() }

            for (index, arg) in cArgs.enumerated() {
                argv[index] = arg
            }
            argv[arguments.count] = nil

            await self?.markServerRunning()
            let status = socks_main(argc, argv)
            guard status != 0 else { return }
            await self?.markServerFailed(code: Int32(status))
        }
    }

    fileprivate func handleConnectionEvent(
        id: Int64,
        protocolRaw: Int32,
        stateRaw: Int32,
        host: String,
        port: UInt16,
        errorCode: Int32
    ) {
        guard
            let protocolType = ProxyConnectionProtocol(rawValue: protocolRaw),
            let state = ProxyConnectionState(rawValue: stateRaw)
        else {
            return
        }

        let title = Self.connectionTitle(host: host, port: port)
        let now = Date()

        if var existing = connectionsByID[id] {
            existing.title = title
            existing.protocolType = protocolType
            existing.state = state
            existing.updatedAt = now
            existing.errorCode = state == .error ? errorCode : nil
            connectionsByID[id] = existing
            moveConnectionToFront(id)
        } else {
            let connection = TrackedConnection(
                id: id,
                title: title,
                protocolType: protocolType,
                state: state,
                updatedAt: now,
                errorCode: state == .error ? errorCode : nil
            )
            connectionsByID[id] = connection
            connectionOrder.insert(id, at: 0)
            totalConnectionAttempts += 1
        }

        trimEndedConnections()
        publishConnections()
    }

    func statusDetail(for connection: TrackedConnection) -> String {
        let timestamp = connection.updatedAt.formatted(date: .omitted, time: .standard)
        switch connection.state {
        case .open:
            return "\(connection.protocolType.title) • Live as of \(timestamp)"
        case .closed:
            return "\(connection.protocolType.title) • Closed at \(timestamp)"
        case .error:
            return "\(connection.protocolType.title) • \(errorDescription(for: connection.errorCode))"
        }
    }

    private func markServerRunning() {
        if serverState != .running {
            serverState = .running
        }
    }

    private func markServerFailed(code: Int32) {
        let failedState = ProxyServerState.failed(code)
        if serverState != failedState {
            serverState = failedState
        }
    }

    private func moveConnectionToFront(_ id: Int64) {
        connectionOrder.removeAll(where: { $0 == id })
        connectionOrder.insert(id, at: 0)
    }

    private func trimEndedConnections() {
        var endedCount = 0
        var idsToRemove = Set<Int64>()

        for id in connectionOrder.reversed() {
            guard let connection = connectionsByID[id] else { continue }
            guard connection.state != .open else { continue }

            endedCount += 1
            if endedCount > maxEndedConnections {
                idsToRemove.insert(id)
            }
        }

        guard !idsToRemove.isEmpty else { return }

        for id in idsToRemove {
            connectionsByID.removeValue(forKey: id)
        }
        connectionOrder.removeAll(where: idsToRemove.contains)
    }

    private func publishConnections() {
        connections = connectionOrder.compactMap { connectionsByID[$0] }
        activeConnectionCount = connections.lazy.filter { $0.state == .open }.count
    }

    private func startTransferPolling() {
        refreshTransferTotals()
        transferTimer = Timer.scheduledTimer(withTimeInterval: transferPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTransferTotals()
            }
        }
    }

    private func refreshTransferTotals() {
        applyTransferTotals(
            downloaded: twosocks_total_downloaded_bytes(),
            uploaded: twosocks_total_uploaded_bytes()
        )
    }

    private func applyTransferTotals(downloaded: UInt64, uploaded: UInt64) {
        let downloadedDelta = downloaded >= lastNativeDownloadedBytes
            ? downloaded - lastNativeDownloadedBytes
            : downloaded
        let uploadedDelta = uploaded >= lastNativeUploadedBytes
            ? uploaded - lastNativeUploadedBytes
            : uploaded

        lastNativeDownloadedBytes = downloaded
        lastNativeUploadedBytes = uploaded

        guard downloadedDelta > 0 || uploadedDelta > 0 else { return }

        sessionDownloadedBytes += downloadedDelta
        sessionUploadedBytes += uploadedDelta
        lifetimeDownloadedBytes += downloadedDelta
        lifetimeUploadedBytes += uploadedDelta
        persistLifetimeTransferTotals()
    }

    private func loadLifetimeTransferTotals() {
        let defaults = UserDefaults.standard
        lifetimeDownloadedBytes = Self.persistedByteCount(forKey: lifetimeDownloadedBytesKey, defaults: defaults)
        lifetimeUploadedBytes = Self.persistedByteCount(forKey: lifetimeUploadedBytesKey, defaults: defaults)
    }

    private func persistLifetimeTransferTotals() {
        let defaults = UserDefaults.standard
        defaults.set(lifetimeDownloadedBytes, forKey: lifetimeDownloadedBytesKey)
        defaults.set(lifetimeUploadedBytes, forKey: lifetimeUploadedBytesKey)
    }

    private static func connectionTitle(host: String, port: UInt16) -> String {
        let normalizedHost = normalizedHostDisplay(host)
        return "\(normalizedHost):\(port)"
    }

    private static func normalizedHostDisplay(_ host: String) -> String {
        guard !host.isEmpty else { return "unknown" }
        guard host.contains(":") else { return host }
        guard !host.hasPrefix("[") && !host.hasSuffix("]") else { return host }
        return "[\(host)]"
    }

    private static func persistedByteCount(forKey key: String, defaults: UserDefaults) -> UInt64 {
        (defaults.object(forKey: key) as? NSNumber)?.uint64Value ?? 0
    }

    private static func byteCountString(_ value: UInt64) -> String {
        guard value > 0 else { return "0 B" }
        return byteCountFormatter.string(fromByteCount: Int64(clamping: value))
    }

    private func errorDescription(for errorCode: Int32?) -> String {
        switch errorCode {
        case .some(3):
            return "Network unreachable"
        case .some(4):
            return "Host unreachable"
        case .some(5):
            return "Connection refused"
        case .some(6):
            return "Connection timed out"
        case .some(7):
            return "Command not supported"
        case .some(8):
            return "Address type not supported"
        case .some(9):
            return "Bind address unavailable"
        case .some(1):
            return "General failure"
        case .some(let code):
            return "Error \(code)"
        case .none:
            return "General failure"
        }
    }

    private func setupBackgroundAudio() {
        guard let url = Bundle.main.url(forResource: "blank", withExtension: "wav") else {
            print("Failed to find background audio resource")
            return
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)

            #if os(iOS)
                try AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
                try AVAudioSession.sharedInstance().setActive(true)
                UIApplication.shared.beginReceivingRemoteControlEvents()
            #endif

            audioPlayer?.configure {
                $0.volume = 0.01
                $0.numberOfLoops = -1
                $0.prepareToPlay()
                $0.play()
            }
        } catch {
            print("Failed to setup background audio:", error.localizedDescription)
        }
    }
}

private extension ContentViewVM {
    static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesActualByteCount = false
        formatter.isAdaptive = true
        return formatter
    }()
}

private extension AVAudioPlayer {
    func configure(_ configuration: (AVAudioPlayer) -> Void) {
        configuration(self)
    }
}
