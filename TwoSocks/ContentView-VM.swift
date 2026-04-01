import AVFoundation
import Foundation
import SwiftUI

private let maxConnectionAttemptLogEntries = 150
private let connectionLogMessageBufferSize = 512
private let proxyPort = 4884
private let activeRuntimePollingInterval = Duration.milliseconds(250)
private let idleRuntimePollingInterval = Duration.seconds(1)

private func drainNativeConnectionLogs() -> [String] {
    var messages: [String] = []
    var buffer = [CChar](repeating: 0, count: connectionLogMessageBufferSize)

    while true {
        let didRead = buffer.withUnsafeMutableBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return false }
            return twosocks_dequeue_connection_log(baseAddress, Int32(pointer.count)) != 0
        }

        guard didRead else { break }
        messages.append(String(cString: buffer))
    }

    return messages
}

private func readNativeRuntimeStats() -> ProxyRuntimeStats {
    var snapshot = TwoSocksStatsSnapshot()
    twosocks_get_stats_snapshot(&snapshot)
    return ProxyRuntimeStats(snapshot: snapshot)
}

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

enum ConnectionLogCategory {
    case success
    case failure
    case info

    var title: String {
        switch self {
        case .success:
            return "Connected"
        case .failure:
            return "Failed"
        case .info:
            return "Info"
        }
    }

    var tint: Color {
        switch self {
        case .success:
            return .green
        case .failure:
            return .red
        case .info:
            return .blue
        }
    }
}

struct ProxyRuntimeStats: Equatable {
    var uploadBytes: UInt64 = 0
    var downloadBytes: UInt64 = 0
    var activeClients: Int = 0
    var successfulConnections: Int = 0
    var failedConnections: Int = 0
    var totalClientSessions: Int = 0
    var serverIsRunning = false
    var lastServerErrorCode: Int32 = 0

    init() {}

    init(snapshot: TwoSocksStatsSnapshot) {
        uploadBytes = snapshot.uploadBytes
        downloadBytes = snapshot.downloadBytes
        activeClients = Int(snapshot.activeClients)
        successfulConnections = Int(snapshot.successfulConnections)
        failedConnections = Int(snapshot.failedConnections)
        totalClientSessions = Int(snapshot.totalClientSessions)
        serverIsRunning = snapshot.serverIsRunning != 0
        lastServerErrorCode = snapshot.lastServerErrorCode
    }

    var totalConnectionAttempts: Int {
        successfulConnections + failedConnections
    }
}

struct ConnectionAttemptLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String

    var category: ConnectionLogCategory {
        if message.localizedCaseInsensitiveContains("failed") {
            return .failure
        }
        if message.localizedCaseInsensitiveContains("connected") {
            return .success
        }
        return .info
    }

    var endpoint: String {
        if let boundary = message.range(of: " failed") {
            return String(message[..<boundary.lowerBound])
        }
        if let boundary = message.range(of: " connected") {
            return String(message[..<boundary.lowerBound])
        }
        return message
    }

    var detail: String {
        if let boundary = message.range(of: " failed") {
            let suffix = message[boundary.lowerBound...].trimmingCharacters(in: .whitespaces)
            return suffix.isEmpty ? "Failed" : suffix.prefix(1).uppercased() + String(suffix.dropFirst())
        }
        if message.localizedCaseInsensitiveContains("connected") {
            return "Connected"
        }
        return message
    }
}

@MainActor
class ContentViewVM: ObservableObject {
    @Published private(set) var serverState: ProxyServerState = .starting
    @Published private(set) var endpointDisplay = "Detecting local IP"
    @Published private(set) var runtimeStats = ProxyRuntimeStats()
    @Published private(set) var serverStartedAt: Date?
    @Published private(set) var connectionAttemptLogs: [ConnectionAttemptLogEntry] = []

    private var audioPlayer: AVAudioPlayer?
    private var runtimePollingTask: Task<Void, Never>?
    private var hasStartedProxy = false

    init() {
        setupBackgroundAudio()
    }

    deinit {
        runtimePollingTask?.cancel()
    }

    func setInterfaceUnavailable() {
        serverState = .waitingForNetwork
        endpointDisplay = "bridge100/en0 not available"
        runtimeStats = ProxyRuntimeStats()
    }

    func startProxy(ipAddress: String) {
        guard !hasStartedProxy else { return }

        hasStartedProxy = true
        serverState = .starting
        endpointDisplay = "\(ipAddress):\(proxyPort)"
        runtimeStats = ProxyRuntimeStats()
        connectionAttemptLogs = []
        serverStartedAt = nil
        twosocks_reset_runtime_state()
        startRuntimePolling()

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

            let status = socks_main(argc, argv)
            guard status != 0 else { return }
            await self?.markServerFailed(code: Int32(status))
        }
    }

    private func startRuntimePolling() {
        guard runtimePollingTask == nil else { return }

        runtimePollingTask = Task.detached(priority: .utility) { [weak self] in
            var lastObservedStats: ProxyRuntimeStats?

            while !Task.isCancelled {
                let messages = drainNativeConnectionLogs()
                let stats = readNativeRuntimeStats()
                let didStatsChange = lastObservedStats != stats

                guard let self else { break }
                if didStatsChange || !messages.isEmpty {
                    await self.refreshRuntimeState(stats: stats, newMessages: messages)
                }

                lastObservedStats = stats

                try? await Task.sleep(for: Self.runtimePollingInterval(for: stats, hasPendingMessages: !messages.isEmpty))
            }
        }
    }

    private func refreshRuntimeState(stats: ProxyRuntimeStats, newMessages: [String]) {
        if runtimeStats != stats {
            runtimeStats = stats
        }

        if !newMessages.isEmpty {
            appendConnectionLogs(newMessages)
        }

        let nextServerState = derivedServerState(from: stats)
        if serverState != nextServerState {
            serverState = nextServerState
        }

        if nextServerState == .running {
            if serverStartedAt == nil {
                serverStartedAt = Date()
            }
        } else if serverStartedAt != nil {
            serverStartedAt = nil
        }
    }

    private func markServerFailed(code: Int32) {
        let failedState = ProxyServerState.failed(code)
        if serverState != failedState {
            serverState = failedState
        }
        if serverStartedAt != nil {
            serverStartedAt = nil
        }
    }

    private func appendConnectionLogs(_ messages: [String]) {
        for message in messages {
            connectionAttemptLogs.insert(ConnectionAttemptLogEntry(message: message), at: 0)
        }

        if connectionAttemptLogs.count > maxConnectionAttemptLogEntries {
            connectionAttemptLogs.removeLast(connectionAttemptLogs.count - maxConnectionAttemptLogEntries)
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

    private func derivedServerState(from stats: ProxyRuntimeStats) -> ProxyServerState {
        if stats.serverIsRunning {
            return .running
        }
        if stats.lastServerErrorCode != 0 {
            return .failed(stats.lastServerErrorCode)
        }
        if hasStartedProxy {
            return .starting
        }
        return .waitingForNetwork
    }

    private static func runtimePollingInterval(for stats: ProxyRuntimeStats, hasPendingMessages: Bool) -> Duration {
        if stats.lastServerErrorCode != 0 {
            return idleRuntimePollingInterval
        }
        if hasPendingMessages || stats.activeClients > 0 || !stats.serverIsRunning {
            return activeRuntimePollingInterval
        }
        return idleRuntimePollingInterval
    }
}

private extension AVAudioPlayer {
    func configure(_ configuration: (AVAudioPlayer) -> Void) {
        configuration(self)
    }
}
