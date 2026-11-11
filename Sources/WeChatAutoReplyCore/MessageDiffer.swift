import Foundation

public struct MessageDiffer {
    private var lastTexts: [String] = []
    private var initialized = false

    public init() {}

    public mutating func reset(with snapshot: ChatSnapshot) {
        lastTexts = snapshot.messages.map(\.text)
        initialized = true
    }

    public mutating func diff(snapshot: ChatSnapshot) -> [ChatMessage] {
        let currentTexts = snapshot.messages.map(\.text)
        guard initialized else {
            lastTexts = currentTexts
            initialized = true
            return []
        }

        let newMessages: [ChatMessage]
        if currentTexts.starts(with: lastTexts) {
            newMessages = Array(snapshot.messages.dropFirst(lastTexts.count))
        } else if let overlap = longestSuffixPrefixOverlap(previous: lastTexts, current: currentTexts) {
            newMessages = Array(snapshot.messages.dropFirst(overlap))
        } else if let last = lastTexts.last, let index = currentTexts.lastIndex(of: last) {
            newMessages = Array(snapshot.messages.dropFirst(index + 1))
        } else {
            let known = Set(lastTexts)
            newMessages = snapshot.messages.filter { !known.contains($0.text) }
        }

        lastTexts = currentTexts
        return newMessages
    }

    private func longestSuffixPrefixOverlap(previous: [String], current: [String]) -> Int? {
        let upperBound = min(previous.count, current.count)
        guard upperBound > 0 else { return nil }
        for size in stride(from: upperBound, through: 1, by: -1) {
            if previous.suffix(size).elementsEqual(current.prefix(size)) {
                return size
            }
        }
        return nil
    }
}
