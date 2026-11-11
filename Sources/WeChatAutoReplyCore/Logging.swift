import Foundation

public final class EventLogger {
    private let path: String
    private let storeMessageContent: Bool
    private let formatter = ISO8601DateFormatter()
    private var handle: FileHandle?

    public init(config: SafetyConfig) {
        self.path = config.resolvedLogPath
        self.storeMessageContent = config.resolvedStoreMessageContent

        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            let fileHandle = FileHandle(forWritingAtPath: path)
            fileHandle?.seekToEndOfFile()
            self.handle = fileHandle
        } catch {
            fputs("警告：无法打开日志文件 \(path)：\(error.localizedDescription)\n", stderr)
            self.handle = nil
        }
    }

    deinit {
        try? handle?.close()
    }

    public func log(
        _ event: String,
        chat: String? = nil,
        text: String? = nil,
        meta: [String: Any] = [:]
    ) {
        var payload: [String: Any] = [
            "ts": formatter.string(from: Date()),
            "event": event,
        ]
        if let chat, !chat.isEmpty {
            payload["chat"] = chat
        }
        if let text {
            if storeMessageContent {
                payload["text"] = text
            } else {
                payload["chars"] = text.count
            }
        }
        for (key, value) in meta {
            payload[key] = value
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let handle else {
            return
        }
        handle.write(data)
        handle.write(Data([0x0A]))
    }
}
