import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    static func deviceIPAddress(interface: String = "bridge100") -> String? {
        var address: String? = nil
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else {
            return nil
        }

        defer { freeifaddrs(ifaddrPointer) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee.ifa_addr.pointee
            let name = String(cString: ptr.pointee.ifa_name)

            guard addr.sa_family == UInt8(AF_INET), name == interface else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                ptr.pointee.ifa_addr,
                socklen_t(addr.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            if result == 0 {
                address = String(cString: hostname)
                break
            }
        }

        return address
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ContentViewVM()
    @State private var address: String?

    var body: some View {
        VStack {
            Text(viewModel.statusMessage)
        }
        .padding()
        .onAppear {
            #if targetEnvironment(simulator)
                var interface = "en0"
            #else
                var interface = "bridge100"
            #endif
            address = AppDelegate.deviceIPAddress(interface: interface)
            if let address {
                viewModel.startProxy(ipAddress: address)
            }
        }
    }
}

#Preview {
    ContentView()
}
