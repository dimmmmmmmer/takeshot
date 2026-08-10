import Foundation

/// What makes a four-digit code cost something to guess.
///
/// Four digits is a decision, not an oversight: a set router is private, and an
/// operator has to be able to read the code across a cart. That decision puts
/// the whole of the defence here. Ten thousand combinations are nothing to a
/// script, so what an attacker pays has to be charged per GUESS.
///
/// Two rules this has always lived by, and they are unchanged:
///
/// - **It is never a refusal.** The unit holding the code is holding the phone
///   that starts the take, and a remote that locks out the right PIN because
///   someone else was guessing is a remote nobody switches on twice. A correct
///   code is always accepted, just later.
/// - **It is the same for a right code and a wrong one.** A delay applied only
///   to failures is an oracle with a two-second clock on it, which is a better
///   oracle than the one it replaced.
///
/// And two it had wrong, both of which made the two seconds decoration:
///
/// - **The count is the PEER's, not the server's.** A server-wide count is a
///   lever pointed the wrong way: it was reachable by anything that could open
///   a socket — one `GET /take-poster` every ten seconds held every PIN answer
///   on the set two seconds late all day — while a guesser paid nothing extra
///   for being the one guessing. Charged per source address, the cost lands on
///   the peer making it and cannot be used against anybody else.
/// - **One answer at a time per peer.** The delay was on each ANSWER, and
///   answers overlapped: five guesses sent together were five answers scheduled
///   together and delivered two seconds later, all five. So the two seconds
///   were paid once per BATCH, and eight sockets each running five guesses a
///   batch walked the space at twenty guesses a second. A peer now has at most
///   one PIN answer on the way; anything it sends behind that is counted and
///   not answered at all, so opening more sockets buys nothing.
///
/// What that is worth, in seconds per thousand guesses, from the constants
/// here and in `RemoteClient` (arithmetic, not a measurement against a real
/// network — see the audit note):
///
/// | | answered guesses a second | 1 000 guesses | the whole 10 000 |
/// | --- | --- | --- | --- |
/// | before | 20 | 50 s | 8 min |
/// | after, one address | 0.5 | 2 000 s | 5 h 33 min |
///
/// The one property this costs: a correct code sent from an address that is at
/// the same moment being used to guess may go unanswered and need a retry.
/// Every page retries on its own watchdog, and on a set network the phone with
/// the code and the machine doing the guessing are not the same address.
///
/// A value type with the clock passed in: the decay is arithmetic, and testing
/// arithmetic should not cost a minute of wall clock.
struct RemotePINTarpit {
    /// Failures inside the window before answers start being held. Small enough
    /// to bite an enumeration in its first second; large enough that a unit
    /// mistyping the code on two phones never meets it.
    static let threshold = 6
    /// How long a failure is remembered. Attempts further apart than this never
    /// add up to anything, which is what "the delay decays" means here.
    static let window: TimeInterval = 60
    /// How long an answer waits while the tarpit is hot for that peer. Two
    /// seconds is barely noticeable behind a button press, and with one answer
    /// in flight per peer it is also the whole interval between one peer's
    /// guesses.
    static let delay: TimeInterval = 2
    /// Peers remembered at once.
    ///
    /// A set network is a router, a switch and the crew; sixty-four addresses is
    /// more than any of them and small enough that the walk below is free. A
    /// peer evicted because something cycled addresses to fill this is a peer
    /// that starts again from cold — which is the same thing having that many
    /// addresses would buy anyway, and it costs an attacker a real interface
    /// per address on a network where every one of them is visible.
    static let maximumPeers = 64

    /// One source address's history.
    private struct Ledger {
        /// Monotonic timestamps of recent failures, oldest first. Only the
        /// newest `threshold + 1` are kept: the question is ever only "were
        /// there MORE than `threshold` inside the window", and an unbounded
        /// list would let the flood this exists to punish allocate freely on a
        /// machine that is recording.
        var failures: [TimeInterval] = []
        /// When this peer's outstanding answer is due out, on the same
        /// monotonic clock. In the past means there is none.
        var answerDue: TimeInterval = 0
    }

    private var ledgers: [String: Ledger] = [:]

    /// Register one PIN verification by `peer` and say how long its answer must
    /// wait — or nil for "do not answer this one at all", which is what a peer
    /// gets while it already has an answer on the way.
    ///
    /// The delay is read from the state BEFORE this attempt is counted, so a
    /// right code and a wrong one presented at the same moment wait exactly as
    /// long — count first and the attempt that crosses the threshold would be
    /// delayed only if it happened to be the wrong one.
    mutating func attempt(peer: String, failed: Bool,
                          now: TimeInterval) -> TimeInterval? {
        var ledger = ledgers[peer] ?? Ledger()
        ledger.failures.removeAll { now - $0 >= Self.window }
        let hot = ledger.failures.count > Self.threshold
        if failed {
            ledger.failures.append(now)
            if ledger.failures.count > Self.threshold + 1 {
                ledger.failures.removeFirst()
            }
        }
        defer {
            ledgers[peer] = ledger
            prune(now: now)
        }
        guard hot else { return 0 }
        // Counted either way — a guess that is not answered is still a guess,
        // and it is what keeps the tarpit hot under a flood.
        guard ledger.answerDue <= now else { return nil }
        ledger.answerDue = now + Self.delay
        return Self.delay
    }

    /// Failures still inside the window for the busiest peer, capped as each
    /// ledger is. Read by the tests to know a burst landed; nothing branches
    /// on it.
    var pressure: Int { ledgers.values.map(\.failures.count).max() ?? 0 }

    /// Whether any peer has an answer on the way at `now`. For the tests: the
    /// one-at-a-time rule is otherwise invisible from outside, and a test that
    /// sends a guess into an occupied slot is a test whose answer never comes.
    func hasAnswerPending(now: TimeInterval) -> Bool {
        ledgers.values.contains { $0.answerDue > now }
    }

    /// Forget peers with nothing left to remember, and hold the map to its cap.
    private mutating func prune(now: TimeInterval) {
        ledgers = ledgers.filter { _, ledger in
            !ledger.failures.isEmpty || ledger.answerDue > now
        }
        guard ledgers.count > Self.maximumPeers else { return }
        // The peer whose answer is due soonest is the one with least still to
        // pay, so it is the cheapest to forget.
        let doomed = ledgers.sorted { $0.value.answerDue < $1.value.answerDue }
            .prefix(ledgers.count - Self.maximumPeers)
        for entry in doomed { ledgers[entry.key] = nil }
    }
}
