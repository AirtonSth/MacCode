import Darwin

struct AcceptRetryBackoff {
    private var nextDelay: useconds_t = 10_000

    mutating func delay(afterErrno code: Int32) -> useconds_t? {
        if code == EINTR || code == ECONNABORTED || code == EAGAIN || code == EWOULDBLOCK {
            return nil
        }
        let delay = nextDelay
        nextDelay = min(nextDelay * 2, 1_000_000)
        return delay
    }

    mutating func reset() {
        nextDelay = 10_000
    }
}
