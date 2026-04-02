import AVFoundation
import Foundation
import SwiftUI

private let proxyPort = 4884

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

@MainActor
class ContentViewVM: ObservableObject {
    @Published private(set) var serverState: ProxyServerState = .starting
    @Published private(set) var endpointDisplay = "Detecting local IP"

    private var audioPlayer: AVAudioPlayer?
    private var hasStartedProxy = false

    init() {
        setupBackgroundAudio()
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
