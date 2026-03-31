import AVFoundation
import Foundation
import SwiftUI

private let maxConnectionAttemptLogEntries = 150
private let connectionLogMessageBufferSize = 512

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

struct ConnectionAttemptLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String

    var isFailure: Bool {
        message.localizedCaseInsensitiveContains("failed")
    }
}

@MainActor
class ContentViewVM: ObservableObject {
    @Published var statusMessage: String = "Starting..."
    @Published var connectionAttemptLogs: [ConnectionAttemptLogEntry] = []

    private var audioPlayer: AVAudioPlayer?
    private var connectionLogPollingTask: Task<Void, Never>?

    private var updateStatus: (String) -> Void {
        { [weak self] message in
            Task { @MainActor in
                self?.statusMessage = message
            }
        }
    }

    init() {
        setupBackgroundAudio()
    }

    deinit {
        connectionLogPollingTask?.cancel()
    }

    func startProxy(ipAddress: String) {
        startConnectionLogPolling()

        let port = 4884
        let updateStatus = self.updateStatus

        Task.detached(priority: .userInitiated) {
            let arguments = ["microsocks", "-p", String(port)]

            // Convert arguments to C-style parameters
            let cArgs = arguments.map { strdup($0) }
            defer { cArgs.forEach { free($0) } }

            let argc = Int32(arguments.count)
            let argv = UnsafeMutablePointer<UnsafePointer<Int8>?>.allocate(capacity: arguments.count + 1)
            defer { argv.deallocate() }

            // Set up arguments
            for (index, arg) in cArgs.enumerated() {
                argv[index] = UnsafePointer(arg)
            }
            argv[arguments.count] = nil

            updateStatus("Running at \(ipAddress):\(port)")

            // Start SOCKS server
            let status = socks_main(argc, argv)

            if status != 0 {
                updateStatus("Failed to start: \(status)")
            }
        }
    }

    private func startConnectionLogPolling() {
        guard connectionLogPollingTask == nil else { return }

        connectionLogPollingTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let messages = drainNativeConnectionLogs()

                if !messages.isEmpty {
                    guard let self else { break }
                    await self.appendConnectionLogs(messages)
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func appendConnectionLogs(_ messages: [String]) {
        for message in messages {
            appendConnectionLog(message)
        }
    }

    private func appendConnectionLog(_ message: String) {
        connectionAttemptLogs.insert(ConnectionAttemptLogEntry(message: message), at: 0)

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
}

private extension AVAudioPlayer {
    func configure(_ configuration: (AVAudioPlayer) -> Void) {
        configuration(self)
    }
}
