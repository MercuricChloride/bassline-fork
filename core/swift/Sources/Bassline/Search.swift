// Searches and their streams, after blnim's queries/stream.nim.
//
// A search is what you ask, and a stream is what it answers. Anything that
// can be asked about something is a search. Asking starts a stream, and the
// search may do as much or as little work as it likes; pulls decide how much
// you take, not how much it does. Each pull gives one answer, and `nil` once
// there's nothing more to give. Answers are whatever the search makes of the
// query (related things, query results, evaluations, objects, functions,
// other searches), and a search answers only from what it knows locally.
//
// Pulling is the whole protocol:
//
// - the streams made here do nothing ahead of a pull, and a consumer that has
//   seen enough just stops pulling; there's no closing or cancelling, and
//   whatever the stream holds goes with it;
// - every pull is late bound: it sees the search as it is at that moment,
//   not as it was when it was asked;
// - `nil` means complete, and the combinators here never pull a complete
//   stream again.
//
// Streams are single-pass (copies share one position) and not `Sendable`:
// a stream belongs to whoever asked.

/// A stream: answers produced one at a time, only when pulled. `nil` means
/// complete.
public struct Answers<Element>: IteratorProtocol, Sequence {
    private let pull: () -> Element?

    /// A stream whose answers come from calling `pull`, until it returns `nil`.
    public init(_ pull: @escaping () -> Element?) {
        self.pull = pull
    }

    /// The elements of `sequence`, pulled one at a time.
    public init<S: Sequence>(_ sequence: S) where S.Element == Element {
        var iterator = sequence.makeIterator()
        self.pull = { iterator.next() }
    }

    /// The next answer, or `nil` if the stream is complete.
    public func next() -> Element? {
        pull()
    }

    /// A stream that's already complete: nothing to give.
    public static var empty: Answers {
        Answers { nil }
    }

    /// A stream with exactly one answer.
    public static func just(_ answer: Element) -> Answers {
        var answer = Optional(answer)
        return Answers {
            defer { answer = nil }
            return answer
        }
    }
}

/// Something that can be asked about a query: asking starts a stream, which
/// gives the answers as they're pulled. Any object can be a search, and so
/// can a closure (`AnySearch`). Answers can be anything, searches included.
public protocol Search<Query, Answer> {
    associatedtype Query
    associatedtype Answer

    /// Starts a stream of answers to `query`.
    func ask(_ query: Query) -> Answers<Answer>
}

extension Search {
    /// `search(query)` is `search.ask(query)`.
    public func callAsFunction(_ query: Query) -> Answers<Answer> {
        ask(query)
    }
}

/// A search made from a closure, or any search with its type erased.
public struct AnySearch<Query, Answer>: Search {
    private let answer: (Query) -> Answers<Answer>

    public init(_ answer: @escaping (Query) -> Answers<Answer>) {
        self.answer = answer
    }

    public init(_ search: some Search<Query, Answer>) {
        self.answer = search.ask
    }

    public func ask(_ query: Query) -> Answers<Answer> {
        answer(query)
    }
}

// MARK: - Stream combinators

extension Answers {
    /// Each answer passed through `transform`.
    public func map<T>(_ transform: @escaping (Element) -> T) -> Answers<T> {
        Answers<T> { next().map(transform) }
    }

    /// The answers `isIncluded` accepts. The others are pulled past.
    public func filter(_ isIncluded: @escaping (Element) -> Bool) -> Answers<Element> {
        Answers {
            while let element = next() {
                if isIncluded(element) { return element }
            }
            return nil
        }
    }

    /// Up to `n` answers, pulling no more than that.
    public func take(_ n: Int) -> [Element] {
        var taken: [Element] = []
        while taken.count < n, let element = next() {
            taken.append(element)
        }
        return taken
    }
}

/// Answers taken fairly from each stream in turn (one from the first, one from
/// the second, and so on), skipping any that are complete, until all are.
/// Fair turns mean an endless stream can't starve the others.
public func alt<Element>(_ streams: Answers<Element>...) -> Answers<Element> {
    alt(streams)
}

/// Answers taken fairly from each stream in turn, until all are complete.
public func alt<Element>(_ streams: [Answers<Element>]) -> Answers<Element> {
    var live = streams
    var turn = 0
    return Answers {
        while !live.isEmpty {
            let index = turn % live.count
            if let element = live[index].next() {
                turn = index + 1
                return element
            }
            // complete: the next stream slides into its place
            live.remove(at: index)
            turn = index
        }
        return nil
    }
}

/// Every answer from the first stream, then every answer from the next, and so
/// on. A stream that never completes holds back all the ones after it, so
/// use `alt` unless every stream but the last is known to end.
public func cat<Element>(_ streams: Answers<Element>...) -> Answers<Element> {
    cat(streams)
}

/// Every answer from each stream in order, one stream after another.
public func cat<Element>(_ streams: [Answers<Element>]) -> Answers<Element> {
    var rest = streams[...]
    return Answers {
        while let first = rest.first {
            if let element = first.next() { return element }
            rest.removeFirst()
        }
        return nil
    }
}

precedencegroup AnswersPipePrecedence {
    associativity: left
    higherThan: AssignmentPrecedence
}

infix operator |> : AnswersPipePrecedence

/// `stream.filter(predicate)`: a closure that answers `Bool` filters.
public func |> <Element>(stream: Answers<Element>, predicate: @escaping (Element) -> Bool) -> Answers<Element> {
    stream.filter(predicate)
}

/// `stream.map(transform)`: any other closure maps.
public func |> <Element, T>(stream: Answers<Element>, transform: @escaping (Element) -> T) -> Answers<T> {
    stream.map(transform)
}

// MARK: - Function combinators

/// `first`, then `second` on its result.
public func compose<A, B, C>(_ first: @escaping (A) -> B, _ second: @escaping (B) -> C) -> (A) -> C {
    { second(first($0)) }
}

/// A running reduction. Each call folds its argument into the accumulator and
/// returns the accumulator so far.
public func fold<A, B>(_ combine: @escaping (B, A) -> B, _ initial: B) -> (A) -> B {
    var accumulator = initial
    return { element in
        accumulator = combine(accumulator, element)
        return accumulator
    }
}

/// Like `fold`, but each call returns the accumulator from before it as well as after.
public func scan<A, B>(_ combine: @escaping (B, A) -> B, _ initial: B) -> (A) -> (previous: B, current: B) {
    var accumulator = initial
    return { element in
        let previous = accumulator
        accumulator = combine(accumulator, element)
        return (previous, accumulator)
    }
}

/// A predicate that stays false once it has failed. After the first rejection
/// it answers `false` without asking `predicate` again.
public func latch<A>(_ predicate: @escaping (A) -> Bool) -> (A) -> Bool {
    fold({ open, element in open && predicate(element) }, true)
}

/// Every function applied to the same argument.
public func split<A, B>(_ functions: [(A) -> B]) -> (A) -> [B] {
    { argument in functions.map { $0(argument) } }
}

/// Pairs each argument with how many came before it.
public func count<A>(_: A.Type = A.self) -> (A) -> (index: Int, element: A) {
    var index = 0
    return { element in
        defer { index += 1 }
        return (index, element)
    }
}
