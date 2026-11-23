import SwiftUI
import Installer

/// The primary install control for the current coordinator state (Install / Cancel / Retry).
struct InstallButtonView: View {
    let state: InstallationCoordinator.State
    let isDisabled: Bool
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        switch state {
        case .idle:
            Button("安装", action: onInstall)
                .buttonStyle(.borderedProminent)
                .disabled(isDisabled)

        case .connecting:
            busy("正在连接……")

        case .connected:
            busy("已连接，等待中……")

        case .waitingForSwitch:
            HStack(spacing: 8) {
                busy("请在 Switch 上选择游戏")
                cancelButton
            }

        case .transferring:
            HStack(spacing: 8) {
                Text("安装中……")
                    .foregroundStyle(.secondary)
                cancelButton
            }

        case .reconnecting(let attempt):
            HStack(spacing: 8) {
                busy("正在重新连接（\(attempt)）……")
                    .foregroundStyle(.orange)
                cancelButton
            }

        case .complete:
            Label("安装完成！", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

        case .error:
            Button("重试", action: onInstall)
                .buttonStyle(.borderedProminent)
                .disabled(isDisabled)
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .lineLimit(2)
        }
    }

    private var cancelButton: some View {
        Button("取消", action: onCancel)
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .fixedSize()
    }
}
