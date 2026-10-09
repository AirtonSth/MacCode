import Foundation

// Side/fork thread capabilities (`agent.thread.fork`, `agent.thread.side`,
// `agent.thread.side.close`, `agent.thread.btw`).
//
// - `agent.thread.fork` branches a thread into a new PERSISTED child. The child
//   carries `parent_thread_id` and `is_ephemeral = false`, and appears in
//   `agent.thread.list`. `message_id` selects the branch point; absent means head.
// - `agent.thread.side` creates an EPHEMERAL fork (a Codex-style `/side`). The
//   child carries `parent_thread_id` and `is_ephemeral = true`, is hidden from
//   `agent.thread.list`, and is deleted on close or at the next host launch.
//   `text` (optional) is sent as the side thread's first message.
// - `agent.thread.side.close` deletes an ephemeral side thread and compensates
//   the provider child session. Closing an already-closed side thread succeeds.
// - `agent.thread.btw` asks a side question against a thread's live session and
//   returns the answer without interrupting the active turn.
//
// All results carry the full thread payload under `thread` except `side.close`
// (empty) and `btw` (`answer`). Ids are UUID strings.

public enum AgentThreadFork: RemoteCodeRPCContract {
    public static let method = "agent.thread.fork"

    public struct Params: Codable, Equatable, Sendable {
        public let threadID: String
        public let messageID: String?

        public init(threadID: String, messageID: String? = nil) {
            self.threadID = threadID
            self.messageID = messageID
        }

        private enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case messageID = "message_id"
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let thread: RemoteCodeJSONValue
    }
}

public enum AgentThreadSide: RemoteCodeRPCContract {
    public static let method = "agent.thread.side"

    public struct Params: Codable, Equatable, Sendable {
        public let threadID: String
        public let text: String?

        public init(threadID: String, text: String? = nil) {
            self.threadID = threadID
            self.text = text
        }

        private enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case text
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let thread: RemoteCodeJSONValue
    }
}

public enum AgentThreadSideClose: RemoteCodeRPCContract {
    public static let method = "agent.thread.side.close"

    public struct Params: Codable, Equatable, Sendable {
        public let threadID: String

        public init(threadID: String) {
            self.threadID = threadID
        }

        private enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public init() {}
    }
}

public enum AgentThreadBtw: RemoteCodeRPCContract {
    public static let method = "agent.thread.btw"

    public struct Params: Codable, Equatable, Sendable {
        public let threadID: String
        public let question: String

        public init(threadID: String, question: String) {
            self.threadID = threadID
            self.question = question
        }

        private enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case question
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let answer: String
    }
}
