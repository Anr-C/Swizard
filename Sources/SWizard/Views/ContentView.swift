import SwiftUI
import Installer
import NativeMTPTransport

struct ContentView: View {
    @Bindable var appState: AppState

    /// USB modes require a connected device; Network mode doesn't.
    private var installRequiresDevice: Bool {
        switch appState.coordinator.transportMode {
        case .dbiBackend, .mtp, .rcm:
            return !appState.isDeviceConnected
        case .network:
            return false
        }
    }

    var body: some View {
        HSplitView {
            leftPanel
                .frame(minWidth: 300)

            rightPanel
                .frame(minWidth: 200)
        }
        .frame(minWidth: 600, minHeight: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            appState.startMonitoring()
        }
        .onChange(of: appState.coordinator.state) {
            appState.updateTransferFlag()
        }
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            transportModePicker

            if appState.coordinator.transportMode == .mtp {
                mtpAdminWarning
            }

            Divider()

            ConnectionStatusView(
                isConnected: appState.isDeviceConnected,
                mode: appState.coordinator.transportMode
            )

            if appState.coordinator.transportMode == .mtp {
                mtpTestSection
                mtpDestinationPicker
            }

            if appState.showInstallHelp {
                installHelpBanner
            }

            if appState.coordinator.transportMode == .network {
                ftpAddressField
            }

            Divider()

            if appState.coordinator.transportMode == .rcm {
                RCMPayloadPickerView(
                    selectedURL: appState.rcmPayloadURL,
                    selectionError: appState.rcmPayloadSelectionError,
                    onSelect: { appState.selectRCMPayload($0) }
                )
                rcmInjectionStatus
            } else {
                DropZoneView { urls in
                    appState.coordinator.queueFiles(urls)
                }
                .frame(height: 120)
                .padding()
            }

            Divider()

            if appState.coordinator.transportMode == .rcm {
                Spacer(minLength: 0)
            } else {
                FileListView(files: appState.coordinator.progress.files)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            bottomBar
                .padding()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Transport Mode Picker

    private var transportModePicker: some View {
        Picker("传输模式", selection: Binding(
            get: { appState.coordinator.transportMode },
            set: { appState.setTransportMode($0) }
        )) {
            ForEach(InstallationCoordinator.TransportMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .disabled(appState.isTransferActive || appState.isRCMInjectionInProgress)
    }

    // MARK: - MTP Test

    private var mtpTestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("测试 MTP 连接") {
                    appState.testMTPConnection()
                }
                .buttonStyle(.bordered)
                .font(.caption)

                if let result = appState.mtpTestResult {
                    Text(result)
                        .font(.caption2)
                        .foregroundStyle(result.contains("成功") ? .green : result.contains("正在测试") ? .secondary : .red)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: - MTP Admin Warning

    private var mtpAdminWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("需要管理员密码")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)
                Text("macOS 在 MTP 模式下访问 USB 需要管理员权限。开始安装时，系统会提示你输入密码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal)
    }

    // MARK: - MTP Destination Picker

    private var mtpDestinationPicker: some View {
        HStack {
            Text("安装到：")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { appState.coordinator.mtpInstallDestination ?? MTPInstallDestination(storageID: 0, rawName: "SD Card install") },
                set: { appState.coordinator.mtpInstallDestination = $0 }
            )) {
                Text("SD 卡").tag(MTPInstallDestination(storageID: 0, rawName: "SD Card install"))
                Text("主机存储").tag(MTPInstallDestination(storageID: 0, rawName: "NAND install"))
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: - Help Banner

    private var installHelpBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text("快速设置提示")
                    .font(.subheadline.weight(.semibold))
                Text(appState.installHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("关闭") {
                appState.dismissInstallHelp()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(10)
    }

    private var ftpAddressField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(.blue)
                    .font(.title3)

                Text("Switch FTP 地址")
                    .font(.subheadline.weight(.semibold))
            }

            HStack(spacing: 8) {
                TextField("输入 Switch IP（例如 192.168.0.96:5000）", text: Binding(
                    get: { appState.coordinator.ftpAddress },
                    set: { appState.coordinator.ftpAddress = $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    appState.validateFTPAddress()
                }

                Button("连接") {
                    appState.validateFTPAddress()
                }
                .buttonStyle(.bordered)
                .disabled(appState.coordinator.ftpAddress.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error = appState.ftpValidationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if appState.isDeviceConnected && appState.coordinator.transportMode == .network {
                Label("FTP 已就绪，可以开始安装", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("活动日志")
                    .font(.headline)

                Spacer()

                Button {
                    appState.exportDiagnosticsLogs()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("导出诊断日志文件")

                Button {
                    appState.copyLogsToClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("复制日志到剪贴板")
                .disabled(appState.coordinator.logs.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if let exportStatus = appState.diagnosticsExportStatusMessage {
                Text(exportStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }

            Divider()

            LogView(entries: appState.coordinator.logs)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            installButton

            Spacer()

            Text(appState.appVersionDisplay)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if appState.coordinator.transportMode != .rcm,
               !appState.coordinator.progress.files.isEmpty {
                Button("清空队列") {
                    appState.coordinator.reset()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var installButton: some View {
        if appState.coordinator.transportMode == .rcm {
            Button(appState.isRCMInjectionInProgress ? "注入中……" : "注入") {
                Task {
                    await appState.injectRCMPayload()
                }
            }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !appState.isDeviceConnected
                        || appState.rcmPayloadURL == nil
                        || appState.isRCMInjectionInProgress
                )
        } else {
            InstallButtonView(
                state: appState.coordinator.state,
                progress: appState.coordinator.progress,
                isDisabled: appState.coordinator.progress.files.isEmpty || installRequiresDevice,
                onInstall: { appState.coordinator.startInstallation() },
                onCancel: { appState.coordinator.cancel() }
            )
        }
    }

    @ViewBuilder
    private var rcmInjectionStatus: some View {
        switch appState.rcmInjectionState {
        case .idle:
            EmptyView()
        case .injecting:
            ProgressView("正在调用 RCM 注入器……")
                .font(.caption)
                .padding(.horizontal)
        case .requestFinished:
            Label("注入请求已结束；请在设备上确认是否启动。", systemImage: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        case .unconfirmed(let message):
            Label(message, systemImage: "questionmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal)
        }
    }
}
