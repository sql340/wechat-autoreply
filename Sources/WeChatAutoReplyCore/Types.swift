import Foundation
import CoreGraphics

public struct ChatMessage: Equatable, Sendable {
    public let text: String
    public let fromMe: Bool
    public let frame: CGRect

    public init(text: String, fromMe: Bool, frame: CGRect = .zero) {
        self.text = text
        self.fromMe = fromMe
        self.frame = frame
    }
}

public struct ChatSnapshot: Equatable, Sendable {
    public let chatName: String?
    public let messages: [ChatMessage]

    public init(chatName: String?, messages: [ChatMessage]) {
        self.chatName = chatName
        self.messages = messages
    }
}

public enum ReplyMode: String, Sendable {
    case draft
    case auto
}
