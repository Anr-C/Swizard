import Foundation
import DBIProtocol

/// Bridges DBISessionDelegate (called from background) to MainActor coordinator.
/// Uses closures to avoid direct cross-actor references.
final class SessionDelegateAdapter: DBISessionDelegate, @unchecked Sendable {
    @MainActor var onLog: (@MainActor @Sendable (String, LogLevel) -> Void)?
    @MainActor var onFileChunk: (@MainActor @Sendable (String, UInt32, UInt64) -> Void)?
    @MainActor var onExit: (@MainActor @Sendable () -> Void)?

    func sessionDidLog(_ message: String, level: LogLevel) {
        Task { @MainActor [weak self] in
            self?.onLog?(message, level)
        }
    }

    func sessionDidSendFileChunk(fileName: String, bytesInChunk: UInt32, totalOffset: UInt64) {
        Task { @MainActor [weak self] in
            self?.onFileChunk?(fileName, bytesInChunk, totalOffset)
        }
    }

    func sessionDidReceiveExit() {
        Task { @MainActor [weak self] in
            self?.onExit?()
        }
    }
}
