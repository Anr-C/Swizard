import SwiftUI
import Installer

struct ConnectionStatusView: View {
    let isConnected: Bool
    let mode: InstallationCoordinator.TransportMode

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? .green : .red)
                .frame(width: 10, height: 10)

            Text(statusText)
                .font(.headline)
                .foregroundStyle(isConnected ? .primary : .secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var statusText: String {
        if mode == .rcm {
            isConnected ? "已检测到 RCM 设备" : "未检测到 RCM 设备"
        } else if isConnected {
            "已连接到 Switch（\(mode.displayName)）"
        } else {
            "等待 Switch 连接……"
        }
    }
}
