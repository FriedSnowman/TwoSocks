import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    static func deviceIPAddress(interface: String) -> String? {
        var address: String?
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else {
            return nil
        }

        defer { freeifaddrs(ifaddrPointer) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            guard let sockaddr = ptr.pointee.ifa_addr else { continue }

        let addr = sockaddr.pointee
            let name = String(cString: ptr.pointee.ifa_name)

            guard addr.sa_family == UInt8(AF_INET), name == interface else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                sockaddr,
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

    private let metricColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 10) {
            headerRow
            metricsRow
            connectionsPanel
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .onAppear(perform: startProxyIfPossible)
    }

    private var headerRow: some View {
        SummaryCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(viewModel.serverState.tint)
                        .frame(width: 8, height: 8)

                    Text("Server \(viewModel.serverState.title)")
                        .font(.headline)
                }

                Text(viewModel.endpointDisplay)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var metricsRow: some View {
        LazyVGrid(columns: metricColumns, spacing: 10) {
            MetricCard(
                title: "Downloaded",
                value: formattedMegabytes(viewModel.runtimeStats.downloadBytes),
                symbol: "arrow.down.circle.fill",
                tint: .blue
            )

            MetricCard(
                title: "Uploaded",
                value: formattedMegabytes(viewModel.runtimeStats.uploadBytes),
                symbol: "arrow.up.circle.fill",
                tint: .orange
            )

            MetricCard(
                title: "Active Clients",
                value: "\(viewModel.runtimeStats.activeClients)",
                symbol: "person.2.fill",
                tint: .indigo
            )

            MetricCard(
                title: "Attempts",
                value: "\(viewModel.runtimeStats.totalConnectionAttempts)",
                symbol: "bolt.horizontal.circle.fill",
                tint: .green
            )
        }
    }

    private var connectionsPanel: some View {
        DashboardPanel(
            title: "Connections"
        ) {
            if viewModel.connectionAttemptLogs.isEmpty {
                ContentUnavailableView {
                    Label("No connections yet", systemImage: "network")
                } description: {
                    Text("New SOCKS connection attempts will appear here in real time.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.connectionAttemptLogs.enumerated()), id: \.element.id) { index, logEntry in
                            ConnectionAttemptLogRow(logEntry: logEntry)

                            if index < viewModel.connectionAttemptLogs.count - 1 {
                                Divider()
                                    .padding(.leading, 36)
                            }
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formattedMegabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_000_000

        if value < 10 {
            return value.formatted(.number.precision(.fractionLength(2))) + " MByte"
        }

        return value.formatted(.number.precision(.fractionLength(1))) + " MByte"
    }

    private func startProxyIfPossible() {
        #if targetEnvironment(simulator)
            let candidateInterfaces = ["en0"]
        #else
            let candidateInterfaces = ["bridge100", "en0"]
        #endif

        if let address = candidateInterfaces.compactMap({ AppDelegate.deviceIPAddress(interface: $0) }).first {
            viewModel.startProxy(ipAddress: address)
        } else {
            viewModel.setInterfaceUnavailable()
        }
    }
}

private struct SummaryCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        CardSurface {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.headline)
                        .foregroundStyle(tint)
                        .frame(width: 20)

                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

private struct DashboardPanel<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        CardSurface {
            VStack(spacing: 0) {
                Text(title)
                    .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

private struct CardSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.18), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ConnectionAttemptLogRow: View {
    let logEntry: ConnectionAttemptLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(logEntry.category.tint)
                .frame(width: 10, height: 10)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(logEntry.endpoint)
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(logEntry.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if logEntry.detail != logEntry.endpoint {
                        Text(logEntry.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }

                    Text(logEntry.category.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(logEntry.category.tint)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
