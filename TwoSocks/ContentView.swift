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
        VStack(alignment: .leading, spacing: 16) {
            Text(viewModel.statusMessage)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox {
                if viewModel.connectionAttemptLogs.isEmpty {
                    Text("No connection attempts yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.connectionAttemptLogs) { logEntry in
                                ConnectionAttemptLogRow(logEntry: logEntry)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live Connection View")
                    Text("Recent attempts are trimmed for performance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

private struct ConnectionAttemptLogRow: View {
    let logEntry: ConnectionAttemptLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(logEntry.timestamp.formatted(date: .omitted, time: .standard))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(logEntry.message)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(logEntry.isFailure ? .red : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ContentView()
}
