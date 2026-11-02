import Foundation
import DBIProtocol
import USBTransport
import MTPTransport
import NativeMTPTransport
import NetworkTransport

/// Mediator: orchestrates USB connection, DBI protocol, and file serving.
/// MainActor-isolated to safely drive @Observable state for SwiftUI.
@Observable
@MainActor
public final class InstallationCoordinator {
    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case connected
        /// DBI session is open but the Switch hasn't requested data yet (user picking a game).
        case waitingForSwitch
        case transferring
        case reconnecting(attempt: Int)
        case complete
        case error(String)

        /// True while an install is in flight and the queue must not change under it.
        public var isBusy: Bool {
            switch self {
            case .connecting, .connected, .waitingForSwitch, .transferring, .reconnecting: true
            case .idle, .complete, .error: false
            }
        }
    }

    public enum TransportMode: String, Sendable, CaseIterable {
        case dbiBackend = "DBI Backend"
        case mtp = "MTP"
        case network = "Network"

        public var displayName: String {
            switch self {
            case .dbiBackend: "DBI 后端"
            case .mtp: "MTP"
            case .network: "网络"
            }
        }
    }

    public private(set) var state: State = .idle
    public var transportMode: TransportMode = .mtp
    public var mtpInstallDestination: MTPInstallDestination?
    public let progress = TransferProgress()
    public private(set) var logs: [LogEntry] = []

    private let transport: any TransportProtocol
    private let mtpDevice: any MTPDeviceProtocol
    private let mtpSession: any MTPSessionProtocol
    private let fileServer = FileServer()
    private let session: DBISession
    private let sessionDelegateAdapter: SessionDelegateAdapter
    private let reconnectPolicy: ReconnectPolicy
    private let ftpClient: any FTPUploadClientProtocol
    private var installTask: Task<Void, Never>?
    private var queuedURLs: [URL] = []
    public var ftpAddress: String = ""
    public private(set) var networkInfo: String?

    public init(
        transport: (any TransportProtocol)? = nil,
        mtpDevice: (any MTPDeviceProtocol)? = nil,
        mtpSession: (any MTPSessionProtocol)? = nil,
        ftpClient: (any FTPUploadClientProtocol)? = nil,
        reconnectPolicy: ReconnectPolicy = .default
    ) {
        self.transport = transport ?? USBTransport().withRetry()
        self.mtpDevice = mtpDevice ?? MTPDevice()
        self.mtpSession = mtpSession ?? PrivilegedMTPSession()
        self.ftpClient = ftpClient ?? FTPUploadClient()
        self.reconnectPolicy = reconnectPolicy
        let adapter = SessionDelegateAdapter()
        self.sessionDelegateAdapter = adapter
        self.session = DBISession()
        self.session.delegate = adapter
    }

    public func queueFiles(_ urls: [URL]) {
        if state == .complete {
            removeAllQueued()
            state = .idle
        }

        var added: [URL] = []
        for url in urls {
            let name = url.lastPathComponent
            // FileServer keys by name, so a second file with the same name can't be served.
            guard !queuedURLs.contains(where: { $0.lastPathComponent == name }) else {
                log("Skipped \(name): already queued", level: .warning)
                continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            queuedURLs.append(url)
            fileServer.register(files: [url])
            progress.register(name: name, totalBytes: size)
            added.append(url)
        }

        if !added.isEmpty {
            log("已添加 \(added.count) 个文件")
        }
    }

    /// Empties the queue but keeps the Activity Log for diagnostics.
    public func clearQueue() {
        guard !state.isBusy else { return }
        removeAllQueued()
        state = .idle
    }

    public func startInstallation() {
        switch state {
        case .idle: break
        case .error: progress.resetProgress()
        default: return
        }
        guard fileServer.fileCount > 0 else {
            log("队列中没有待安装的文件")
            return
        }

        sessionDelegateAdapter.onLog = { [weak self] message, level in
            Task { @MainActor in self?.log(message, level: level) }
        }
        sessionDelegateAdapter.onFileChunk = { [weak self] fileName, bytesInChunk, _ in
            Task { @MainActor in
                guard let self else { return }
                if self.state == .waitingForSwitch { self.state = .transferring }
                self.progress.applyChunk(fileName: fileName, bytesInChunk: bytesInChunk)
            }
        }

        installTask = Task { [weak self] in
            await self?.runInstallation()
        }
    }

    public func cancel() {
        installTask?.cancel()
        installTask = nil
        // FTP client uses curl Process which is killed when task is cancelled
        networkInfo = nil
        log("已请求取消")
    }

    public func reset() {
        cancel()
        // FTP client uses curl Process which is killed when task is cancelled
        state = .idle
        removeAllQueued()
        logs.removeAll()
        networkInfo = nil
    }

    /// The queue lives in three places (URLs, progress rows, file server); change them together.
    private func removeAllQueued() {
        queuedURLs.removeAll()
        progress.clear()
        fileServer.removeAll()
    }

    // MARK: - Private

    private func runInstallation() async {
        switch transportMode {
        case .dbiBackend:
            await runDBIBackendInstallation()
        case .mtp:
            await runMTPInstallation()
        case .network:
            await runNetworkInstallation()
        }
        installTask = nil
    }

    // MARK: - DBI Backend Path

    private func runDBIBackendInstallation() async {
        state = .connecting
        log("正在通过 DBI 后端连接 Switch……", level: .info)

        do {
            try await transport.connect()
            state = .connected
            log("已连接到 Switch", level: .info)

            try await runSessionWithReconnect()

            state = .complete
            log("安装完成！", level: .info)
        } catch is CancellationError {
            state = .idle
            log("安装已取消", level: .warning)
        } catch {
            state = .error(error.localizedDescription)
            log("错误：\(error.localizedDescription)", level: .error)
        }

        try? await transport.disconnect()
    }

    private func runSessionWithReconnect() async throws {
        var reconnectAttempts = 0

        while true {
            do {
                state = .waitingForSwitch
                try await session.run(transport: transport, fileServer: fileServer)
                return
            } catch let error as USBError where error == .disconnected {
                guard reconnectAttempts < reconnectPolicy.maxAttempts else {
                    throw error
                }

                reconnectAttempts += 1
                state = .reconnecting(attempt: reconnectAttempts)
                log("连接已断开，正在重新连接（\(reconnectAttempts)/\(reconnectPolicy.maxAttempts)）……", level: .warning)

                try? await transport.disconnect()

                if reconnectPolicy.baseDelay > 0 {
                    try await Task.sleep(for: .seconds(reconnectPolicy.baseDelay))
                }

                try await transport.connect()
                log("已重新连接到 Switch", level: .info)
            }
        }
    }

    // MARK: - MTP Path

    private func runMTPInstallation() async {
        state = .connecting
        log("正在通过 MTP 连接 Switch……", level: .info)
        log("MTP 模式需要管理员权限才能从 macOS 接管 USB 设备。", level: .warning)

        let files = queuedURLs.map { url -> PrivilegedMTPSession.FileToInstall in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            return PrivilegedMTPSession.FileToInstall(path: url.path, name: url.lastPathComponent, size: size)
        }

        let mtpSess = mtpSession

        do {
            try await mtpSess.install(
                files: files,
                targetStorageID: mtpInstallDestination?.storageID,
                onProgress: { [weak self] fileName, sent, total in
                    Task { @MainActor in
                        if self?.state == .connecting { self?.state = .transferring }
                        self?.progress.updateProgress(fileName: fileName, transferredBytes: sent)
                    }
                },
                onLog: { [weak self] (message: String) in
                    Task { @MainActor in
                        self?.log("[MTP] \(message)", level: .debug)
                    }
                }
            )

            state = .complete
            log("安装完成！", level: .info)
        } catch is CancellationError {
            state = .idle
            log("安装已取消", level: .warning)
        } catch {
            state = .error(error.localizedDescription)
            log("错误：\(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Network Path

    private func runNetworkInstallation() async {
        state = .connecting

        guard let connection = FTPConnectionInfo.parse(ftpAddress) else {
            state = .error("FTP 地址无效。请输入 Switch 的 IP:端口（例如 192.168.0.96:5000）")
            log("FTP 地址无效：\(ftpAddress)", level: .error)
            return
        }

        log("正在连接 Switch FTP：\(connection.displayString)……", level: .info)

        do {
            state = .transferring

            for url in queuedURLs {
                let fileName = url.lastPathComponent
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0

                try await ftpClient.upload(
                    file: url,
                    to: connection,
                    onProgress: { [weak self] percentage in
                        Task { @MainActor in
                            let bytes = UInt64(Double(fileSize) * percentage / 100.0)
                            self?.progress.updateProgress(fileName: fileName, transferredBytes: bytes)
                        }
                    },
                    onLog: { [weak self] (message: String) in
                        Task { @MainActor in
                            self?.log("[FTP] \(message)", level: .debug)
                        }
                    }
                )

                log("已通过 FTP 安装 \(fileName)", level: .info)
            }

            state = .complete
            log("所有文件均已通过 FTP 安装！", level: .info)
        } catch is CancellationError {
            state = .idle
            log("FTP 传输已取消", level: .warning)
        } catch {
            state = .error(error.localizedDescription)
            log("FTP 错误：\(error.localizedDescription)", level: .error)
        }
    }

    public func log(_ message: String, level: LogLevel = .info) {
        logs.append(LogEntry(message: message, level: level))
    }
}
