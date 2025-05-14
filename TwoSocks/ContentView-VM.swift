import AVFoundation
import Foundation
import SwiftUI

@MainActor
class ContentViewVM: ObservableObject {
    @Published var statusMessage: String = "Starting..."
    private var audioPlayer: AVAudioPlayer?
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

    func startProxy(ipAddress: String) {
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
