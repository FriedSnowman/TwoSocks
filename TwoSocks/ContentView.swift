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
    @StateObject private var viewModel: ContentViewVM
    private let startsProxyOnAppear: Bool

    private let metricColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: ContentViewVM())
        startsProxyOnAppear = true
    }

    @MainActor
    init(viewModel: ContentViewVM, startsProxyOnAppear: Bool = true) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.startsProxyOnAppear = startsProxyOnAppear
    }

    var body: some View {
        VStack(spacing: 16) {
            metricsRow
            connectionsPanel
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            headerRow
        }
        .onAppear {
            guard startsProxyOnAppear else { return }
            startProxyIfPossible()
        }
    }

    private var headerRow: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Server \(viewModel.serverState.title)")
                            .font(.subheadline.weight(.semibold))

                        if viewModel.serverState != .running {
                            Text(viewModel.serverState.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } icon: {
                    Image(systemName: viewModel.serverState.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(viewModel.serverState.tint)
                }

                if viewModel.serverState == .running {
                    Spacer(minLength: 12)

                    Text(viewModel.endpointDisplay)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)

            Divider()
        }
        .background(.bar)
    }

    private var metricsRow: some View {
        LazyVGrid(columns: metricColumns, spacing: 10) {
            MetricCard(
                title: "Downloaded",
                value: viewModel.downloadedDisplay,
                symbol: "arrow.down.circle.fill",
                tint: .blue,
                secondaryTitle: "Total",
                secondaryValue: viewModel.lifetimeDownloadedDisplay
            )

            MetricCard(
                title: "Uploaded",
                value: viewModel.uploadedDisplay,
                symbol: "arrow.up.circle.fill",
                tint: .orange,
                secondaryTitle: "Total",
                secondaryValue: viewModel.lifetimeUploadedDisplay
            )
        }
    }

    private var connectionsPanel: some View {
        DashboardPanel(
            title: viewModel.connectionsPanelTitle
        ) {
            if viewModel.connections.isEmpty {
                ContentUnavailableView {
                    Label("No connections yet", systemImage: "network")
                } description: {
                    Text("Open traffic through the proxy to see status here.")
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !viewModel.liveConnections.isEmpty {
                            ConnectionsSectionView(
                                title: "Open",
                                connections: viewModel.liveConnections,
                                detailProvider: viewModel.statusDetail(for:)
                            )
                        }

                        if !viewModel.recentConnections.isEmpty {
                            ConnectionsSectionView(
                                title: viewModel.liveConnections.isEmpty ? "Recent" : "Recent Activity",
                                connections: viewModel.recentConnections,
                                detailProvider: viewModel.statusDetail(for:)
                            )
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    var secondaryTitle: String?
    var secondaryValue: String?

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

                if let secondaryTitle, let secondaryValue {
                    HStack(alignment: .center, spacing: 10) {
                        Text(value)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Spacer(minLength: 8)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(secondaryTitle)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)

                            Text(secondaryValue)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                } else {
                    Text(value)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

private struct ConnectionRowView: View {
    let connection: TrackedConnection
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: connection.protocolType.systemImage)
                .font(.headline)
                .foregroundStyle(connection.state.tint)
                .frame(width: 24, height: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(connection.title)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .textSelection(.enabled)

                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            ConnectionStateBadge(state: connection.state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
    }
}

private struct ConnectionStateBadge: View {
    let state: ProxyConnectionState

    var body: some View {
        Text(state.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(state.tint.opacity(0.14), in: Capsule())
    }
}

private struct ConnectionsSectionView: View {
    let title: String
    let connections: [TrackedConnection]
    let detailProvider: (TrackedConnection) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 2)

            CardSurface {
                VStack(spacing: 4) {
                    ForEach(connections) { connection in
                        ConnectionRowView(
                            connection: connection,
                            detail: detailProvider(connection)
                        )

                        if connection.id != connections.last?.id {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
            }
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

#if DEBUG
#Preview("Dashboard") {
    ContentView(
        viewModel: ContentViewVM.previewDashboard(),
        startsProxyOnAppear: false
    )
}
#endif
