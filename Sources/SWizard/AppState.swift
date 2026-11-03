import Foundation
import AppKit
import os
import Installer
import USBTransport
import NativeMTPTransport
import NetworkTransport
import DBIProtocol
import RCMTransport

protocol PreferencesStore {
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Bool, forKey defaultName: String)
    func string(forKey defaultName: String) -> String?
    func setString(_ value: String, forKey defaultName: String)
}

extension UserDefaults: PreferencesStore {
    func setString(_ value: String, forKey defaultName: String) {
        set(value, forKey: defaultName)
    }
}

/// Top-level observable state for the app.
@Observable
@MainActor
final class AppState {
    enum RCMInjectionState: Equatable {
        case idle
        case injecting
        case requestFinished
        case unconfirmed(String)
        case failed(String)
    }

    private static let installHelpDismissedKey = "swizard.installHelp.dismissed"
    private static let lastFTPAddressKey = "swizard.ftp.lastAddress"
    private static let lastTransportModeKey = "swizard.transportMode"
    private static let lastRCMPayloadPathKey = "swizard.rcm.lastPayloadPath"

    let coordinator = InstallationCoordinator()
    let deviceMonitor: USBDeviceMonitor
    var isDeviceConnected = false
    var rcmPayloadURL: URL?
    var rcmPayloadSelectionError: String?
    private(set) var rcmInjectionState: RCMInjectionState = .idle
    var showInstallHelp: Bool
    var diagnosticsExportStatusMessage: String?
    private var monitorTask: Task<Void, Never>?
    private let preferences: PreferencesStore
    private let appVersionProvider: any AppVersionProviding
    private let diagnosticsExportRunner: any DiagnosticsExportRunning
    private let rcmDeviceDetector: @Sendable () -> Bool
    private let rcmInjector: (any RCMInjector)?

    /// Shared flag for device mutex — set by coordinator state changes.
    private let _isTransferActive = TransferActiveFlag()

    init(
        preferences: PreferencesStore = UserDefaults.standard,
        appVersionProvider: any AppVersionProviding = DefaultAppVersionProvider(),
        diagnosticsExportRunner: (any DiagnosticsExportRunning)? = nil,
        rcmInjector: (any RCMInjector)? = nil,
        rcmDeviceDetector: @escaping @Sendable () -> Bool = {
            USBDeviceScanner.hasDevice(vendorID: RCMDevice.vendorID, productID: RCMDevice.productID)
        }
    ) {
        let flag = _isTransferActive
        self.preferences = preferences
        self.appVersionProvider = appVersionProvider
        self.rcmInjector = rcmInjector
        self.rcmDeviceDetector = rcmDeviceDetector
        if let diagnosticsExportRunner {
            self.diagnosticsExportRunner = diagnosticsExportRunner
        } else {
            self.diagnosticsExportRunner = DiagnosticsExportUseCase(
                formatter: PlainTextDiagnosticsFormatter(),
                exporter: SavePanelDiagnosticsExporter()
            )
        }
        self.deviceMonitor = USBDeviceMonitor { flag.value }
        self.showInstallHelp = !preferences.bool(forKey: Self.installHelpDismissedKey)

        // Restore last FTP address
        if let lastAddress = preferences.string(forKey: Self.lastFTPAddressKey) {
            coordinator.ftpAddress = lastAddress
        }

        if let lastPayloadPath = preferences.string(forKey: Self.lastRCMPayloadPathKey) {
            let lastPayloadURL = URL(fileURLWithPath: lastPayloadPath)
            rcmPayloadURL = lastPayloadURL
            if !FileManager.default.fileExists(atPath: lastPayloadURL.path) {
                rcmPayloadSelectionError = "上次选择的 payload 文件不存在，请重新选择。"
            }
        }

        // Restore last transport mode
        if let savedMode = preferences.string(forKey: Self.lastTransportModeKey),
           let mode = InstallationCoordinator.TransportMode.allCases.first(where: { $0.rawValue == savedMode }) {
            coordinator.transportMode = mode
        }
    }

    var isTransferActive: Bool {
        switch coordinator.state {
        case .transferring, .reconnecting: return true
        default: return false
        }
    }

    var appVersionDisplay: String {
        let version = appVersionProvider.displayVersion
        guard shouldPrefixVersion(version) else { return version }
        return "v\(version)"
    }

    private func shouldPrefixVersion(_ version: String) -> Bool {
        guard let first = version.first else { return false }
        return first.isNumber
    }

    /// Help text depends on the selected mode.
    var installHelpText: String {
        switch coordinator.transportMode {
        case .dbiBackend:
            "在 Switch 上打开 DBI，选择“运行 DBI 后端”，然后连接 USB。"
        case .mtp:
            "在 Switch 上打开 DBI →“运行 MTP 响应程序”。SWizard 将提示你输入一次管理员密码，以便从 macOS 接管 USB。"
        case .network:
            "在 Switch 上依次选择：DBI → 启动 FTP → 安装到 SD 卡。然后输入 Switch 屏幕上显示的 IP:端口。"
        case .rcm:
            "选择或拖入 .bin payload 文件。"
        }
    }

    func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task {
            // Poll for device based on current transport mode
            var wasConnected = false
            var previousMode: InstallationCoordinator.TransportMode?
            while !Task.isCancelled {
                let found: Bool
                let mode = coordinator.transportMode
                switch mode {
                case .dbiBackend:
                    // Use USBDeviceMonitor's underlying check (libusb, PID 0x3000)
                    found = USBDeviceScanner.findDevice(
                        vendorID: NintendoSwitchUSB.vendorID,
                        productID: NintendoSwitchUSB.backendProductID
                    ) != nil
                case .mtp:
                    // Scan for MTP PID (0x201D)
                    found = USBDeviceScanner.findDevice(
                        vendorID: NintendoSwitchUSB.vendorID,
                        productID: NintendoSwitchUSB.mtpProductID
                    ) != nil
                case .network:
                    // Network mode: "connected" when user validated FTP address
                    found = ftpAddressValidated
                case .rcm:
                    found = rcmDeviceDetector()
                }

                if found != wasConnected || mode != previousMode {
                    isDeviceConnected = found
                    wasConnected = found
                    if mode == .rcm {
                        coordinator.log(
                            found
                                ? "已检测到 RCM 设备（VID 0x0955，PID 0x7321）"
                                : "未检测到 RCM 设备",
                            level: found ? .info : .warning
                        )
                    }
                }
                previousMode = mode

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func updateTransferFlag() {
        _isTransferActive.value = isTransferActive
    }

    private func logMTP(_ msg: String, level: DBIProtocol.LogLevel = .info) {
        coordinator.log("[MTP] \(msg)", level: level)
    }

    private func runMTPDiagnostic() async {
        logMTP("正在开始 MTP 连接测试……", level: .info)

        // Step 1: Scan for device (no admin needed)
        let devices = USBDeviceScanner.findDevices(vendorID: NintendoSwitchUSB.vendorID)
        if devices.isEmpty {
            logMTP("未找到 Nintendo USB 设备", level: .error)
            mtpTestResult = "失败 — 未找到 Nintendo 设备。请确认 Switch 已连接且 DBI 正在运行 MTP。"
            return
        }
        for d in devices {
            logMTP("已发现设备：\(d.description)", level: .info)
        }

        // Step 2: Run a quick MTP handshake test via PrivilegedMTPSession
        // This prompts for admin password, then does DeviceCapture → OpenSession → CloseSession
        logMTP("正在测试 MTP 握手（将提示输入管理员密码）……", level: .warning)

        let session = mtpSessionFactory()
        do {
            // Install with empty file list — just tests the handshake
            try await session.install(
                files: [],
                targetStorageID: nil,
                onProgress: { _, _, _ in },
                onLog: { [weak self] msg in
                    Task { @MainActor in self?.logMTP(msg, level: .debug) }
                }
            )
            logMTP("成功 — MTP 握手已完成！", level: .info)
            mtpTestResult = "成功 — 已确认 MTP 访问正常！"
        } catch {
            logMTP("MTP 握手失败：\(error.localizedDescription)", level: .error)
            let found = devices.map(\.description).joined(separator: ", ")
            mtpTestResult = "失败 — \(found)。\(error.localizedDescription)"
        }
    }

    func dismissInstallHelp() {
        showInstallHelp = false
        preferences.set(true, forKey: Self.installHelpDismissedKey)
    }

    // MARK: - Copy Logs

    /// Formats all activity log entries as a string and copies to clipboard.
    @discardableResult
    func copyLogsToString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        let text = coordinator.logs.map { entry in
            let level = "[\(String(describing: entry.level).uppercased())]"
            let time = formatter.string(from: entry.timestamp)
            return "\(time) \(level) \(entry.message)"
        }.joined(separator: "\n")

        return text
    }

    func copyLogsToClipboard() {
        let text = copyLogsToString()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportDiagnosticsLogs() {
        let request = DiagnosticsExportRequest(
            appVersion: appVersionProvider.displayVersion,
            transportMode: coordinator.transportMode.rawValue,
            installationState: coordinator.state.diagnosticsLabel
        )

        do {
            let exportedURL = try diagnosticsExportRunner.export(request: request, entries: coordinator.logs)
            if let exportedURL {
                diagnosticsExportStatusMessage = "诊断日志已导出到 \(exportedURL.lastPathComponent)。"
            } else {
                diagnosticsExportStatusMessage = "已取消导出诊断日志。"
            }
        } catch {
            diagnosticsExportStatusMessage = "导出诊断日志失败：\(error.localizedDescription)"
        }
    }

    // MARK: - FTP Address Validation

    var ftpValidationError: String?
    var ftpAddressValidated: Bool = false

    func validateFTPAddress() {
        let address = coordinator.ftpAddress.trimmingCharacters(in: .whitespaces)

        if address.isEmpty {
            ftpValidationError = "请输入 Switch 屏幕上显示的 IP 地址"
            ftpAddressValidated = false
            return
        }

        guard FTPConnectionInfo.parse(address) != nil else {
            ftpValidationError = "格式无效。请使用 IP:端口格式（例如 192.168.0.96:5000）"
            ftpAddressValidated = false
            return
        }

        ftpValidationError = nil
        ftpAddressValidated = true
        preferences.setString(address, forKey: Self.lastFTPAddressKey)
    }

    /// Change transport mode and persist the choice.
    func setTransportMode(_ mode: InstallationCoordinator.TransportMode) {
        coordinator.transportMode = mode
        preferences.setString(mode.rawValue, forKey: Self.lastTransportModeKey)
    }

    func selectRCMPayload(_ url: URL) {
        guard url.isFileURL,
              url.pathExtension.lowercased() == "bin" else {
            rcmPayloadSelectionError = "请选择 .bin 格式的 payload 文件。"
            coordinator.log("RCM payload 文件格式无效：\(url.lastPathComponent)", level: .error)
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            rcmPayloadSelectionError = "所选 payload 文件不存在或不是普通文件。"
            coordinator.log("RCM payload 文件不可用：\(url.path)", level: .error)
            return
        }

        let standardizedURL = url.standardizedFileURL
        rcmPayloadURL = standardizedURL
        rcmPayloadSelectionError = nil
        rcmInjectionState = .idle
        preferences.setString(standardizedURL.path, forKey: Self.lastRCMPayloadPathKey)
        coordinator.log("已选择 RCM payload：\(standardizedURL.lastPathComponent)", level: .info)
    }

    var isRCMInjectionInProgress: Bool {
        if case .injecting = rcmInjectionState { return true }
        return false
    }

    func injectRCMPayload() async {
        guard coordinator.transportMode == .rcm else {
            failRCMInjection("请先切换到 RCM 模式。")
            return
        }
        guard !isRCMInjectionInProgress else { return }
        guard rcmDeviceDetector() else {
            isDeviceConnected = false
            failRCMInjection("未检测到 RCM 设备，请检查连接后重试。")
            return
        }
        guard let payloadURL = rcmPayloadURL,
              payloadURL.isFileURL,
              payloadURL.pathExtension.lowercased() == "bin" else {
            failRCMInjection("请先选择有效的 .bin payload 文件。")
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: payloadURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            rcmPayloadSelectionError = "所选 payload 文件不存在或不是普通文件。"
            failRCMInjection("payload 文件不可用，请重新选择。")
            return
        }

        isDeviceConnected = true
        rcmInjectionState = .injecting
        coordinator.log("正在将 payload 交给 RCM 注入器：\(payloadURL.lastPathComponent)", level: .info)

        do {
            let injector = rcmInjector ?? FuseeGeleeInjector()
            try await injector.inject(payloadAt: payloadURL)
            rcmInjectionState = .requestFinished
            coordinator.log("RCM 注入完成（设备已停止响应，属正常现象）。请在 Switch 上确认是否启动。", level: .info)
        } catch let RCMInjectionError.triggerUnconfirmed(reason) {
            let message = "payload 已发送，但触发请求\(reason)；请在设备上确认是否启动。"
            rcmInjectionState = .unconfirmed(message)
            coordinator.log("RCM 注入状态未确认：\(message)", level: .warning)
        } catch {
            failRCMInjection(error.localizedDescription)
        }
    }

    private func failRCMInjection(_ message: String) {
        rcmInjectionState = .failed(message)
        coordinator.log("RCM 注入失败：\(message)", level: .error)
    }

    // MARK: - MTP Connection Test

    var mtpTestResult: String?

    /// Injectable for testing — defaults to real PrivilegedMTPSession.
    var mtpSessionFactory: () -> any MTPSessionProtocol = { PrivilegedMTPSession() }

    func testMTPConnection() {
        mtpTestResult = "正在测试……"
        Task {
            await runMTPDiagnostic()
        }
    }
}

private extension InstallationCoordinator.State {
    var diagnosticsLabel: String {
        switch self {
        case .idle: "idle"
        case .connecting: "connecting"
        case .connected: "connected"
        case .transferring: "transferring"
        case .reconnecting(let attempt): "reconnecting(\(attempt))"
        case .complete: "complete"
        case .error(let message): "error(\(message))"
        }
    }
}

/// Thread-safe flag bridging @MainActor state to background polling.
/// Uses os_unfair_lock for safe concurrent read/write.
final class TransferActiveFlag: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    var value: Bool {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
