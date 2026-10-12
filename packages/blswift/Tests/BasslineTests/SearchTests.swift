import Testing
@testable import Bassline

/// A source that counts how often it's pulled, so tests can check laziness.
private final class Source {
    var elements: [Int]
    private(set) var pulls = 0
    private var position = 0

    init(_ elements: [Int]) {
        self.elements = elements
    }

    var stream: Answers<Int> {
        Answers {
            self.pulls += 1
            guard self.position < self.elements.count else { return nil }
            defer { self.position += 1 }
            return self.elements[self.position]
        }
    }
}

/// Values learned so far, as a search: asked with a shape, it answers the
/// bindings of every fact that fits, seeing whatever is known when it's pulled.
private final class Facts: Search {
    var values: [Value] = []

    func ask(_ shape: Shape) -> Answers<Value.Dict> {
        var index = 0
        return Answers {
            while index < self.values.count {
                defer { index += 1 }
                if let bindings = try? shape.extract(from: self.values[index]) { return bindings }
            }
            return nil
        }
    }
}

private func naturals() -> Answers<Int> {
    var n = 0
    return Answers {
        defer { n += 1 }
        return n
    }
}

@Suite("streams")
struct StreamTests {
    @Test func nothingIsPulledAheadOfTheConsumer() {
        let source = Source([1, 2, 3, 4, 5, 6])
        let evens = source.stream.map { $0 * 10 }.filter { $0 % 20 == 0 }
        #expect(source.pulls == 0)
        #expect(evens.next() == 20)
        #expect(source.pulls == 2)
        #expect(evens.take(1) == [40])
        #expect(source.pulls == 4)
    }

    @Test func takePullsNoMoreThanItNeeds() {
        let source = Source([1, 2, 3])
        #expect(source.stream.take(0) == [])
        #expect(source.pulls == 0)
        #expect(source.stream.take(2) == [1, 2])
        #expect(source.pulls == 2)
        #expect(source.stream.take(5) == [3])
        #expect(naturals().take(3) == [0, 1, 2])
    }

    @Test func filterPullsPastRejectedAnswers() {
        #expect(Array(Answers([1, 2, 3, 4, 5]).filter { $0.isMultiple(of: 2) }) == [2, 4])
        #expect(Array(Answers([1, 3]).filter { $0.isMultiple(of: 2) }) == [])
    }

    @Test func aStreamIsSinglePass() {
        let stream = Answers([1, 2, 3])
        #expect(stream.next() == 1)
        #expect(Array(stream) == [2, 3])
        #expect(stream.next() == nil)
    }

    @Test func emptyAndJust() {
        #expect(Answers<Int>.empty.next() == nil)
        let one = Answers.just(7)
        #expect(one.next() == 7)
        #expect(one.next() == nil)
    }

    @Test func pullsAreLateBound() {
        let source = Source([1])
        let doubled = source.stream.map { $0 * 2 }
        #expect(doubled.next() == 2)
        source.elements += [2, 3]
        #expect(Array(doubled) == [4, 6])
    }

    @Test func altTakesFairTurnsAndSkipsCompleteStreams() {
        let merged = alt(Answers([1, 2, 3]), Answers([10, 20]), Answers([100]))
        #expect(Array(merged) == [1, 10, 100, 2, 20, 3])
        #expect(Array(alt([Answers<Int>]())) == [])
    }

    @Test func altLetsEveryStreamThroughEvenBesideAnEndlessOne() {
        let merged = alt(naturals(), Answers([-1, -2]))
        #expect(merged.take(6) == [0, -1, 1, -2, 2, 3])
    }

    @Test func altAndCatNeverPullACompleteStreamAgain() {
        let short = Source([1])
        let long = Source([10, 20, 30])
        #expect(Array(alt(short.stream, long.stream)) == [1, 10, 20, 30])
        #expect(short.pulls == 2)

        let first = Source([1])
        let second = Source([2])
        let joined = cat(first.stream, second.stream)
        #expect(Array(joined) == [1, 2])
        #expect(joined.next() == nil)
        #expect(first.pulls == 2)
        #expect(second.pulls == 2)
    }

    @Test func catExhaustsEachStreamInOrder() {
        #expect(Array(cat(Answers([1, 2]), Answers([]), Answers([3]))) == [1, 2, 3])
        #expect(cat(Answers([1]), naturals()).take(3) == [1, 0, 1])
    }

    @Test func pipeFiltersWithPredicatesAndMapsOtherwise() {
        let result = Answers([1, 2, 3, 4]) |> { $0 > 1 } |> { "\($0)" }
        #expect(Array(result) == ["2", "3", "4"])
    }
}

@Suite("searches")
struct SearchTests {
    @Test func askingStartsAStreamThatAnswersFromWhatIsKnown() throws {
        let facts = Facts()
        facts.values = try Value.readDocument(#"(person "ann" 31) (pet "rex" dog) (person "bo" 25)"#)
        let person = try Shape(bassline: Value(reading: "(shape (person name age) {name age})"))

        let answers = facts.ask(person)
        #expect(answers.next()?[.symbol("name")] == "ann")
        // learned after asking, before the stream was complete
        facts.values.append(try Value(reading: #"(person "cy" 40)"#))
        #expect(answers.map { $0[.symbol("name")] }.take(5) == ["bo", "cy"])
    }

    @Test func searchesComposeWithoutKnowingAboutEachOther() throws {
        let people = Facts()
        let pets = Facts()
        people.values = try Value.readDocument(#"(person "ann" 31) (person "bo" 25)"#)
        pets.values = try Value.readDocument(#"(person "rex" 3)"#)
        let person = try Shape(bassline: Value(reading: "(shape (person name age) {name age})"))

        let both = AnySearch { alt(people($0), pets($0)) }
        #expect(Array(both(person).map { $0[.symbol("name")] }) == ["ann", "rex", "bo"])
    }

    @Test func searchesCanAnswerSearches() throws {
        let people = Facts()
        let pets = Facts()
        people.values = try Value.readDocument(#"(person "ann" 31)"#)
        pets.values = try Value.readDocument(#"(person "rex" 3)"#)
        let person = try Shape(bassline: Value(reading: "(shape (person name age) {name age})"))

        // asked about a head, answers the searches that know things under it
        let directory = AnySearch { (head: Symbol) -> Answers<any Search<Shape, Value.Dict>> in
            head == "person" ? Answers([people, pets]) : .empty
        }
        let everyone = Array(directory("person").map { $0(person) }).flatMap { Array($0) }
        #expect(everyone.map { $0[.symbol("name")] } == ["ann", "rex"])
        #expect(directory("planet").next() == nil)
    }

    @Test func anySearchErasesAnObject() throws {
        let facts = Facts()
        facts.values = [try Value(reading: "(person \"ann\" 31)")]
        let erased = AnySearch(facts)
        let person = try Shape(bassline: Value(reading: "(shape (person name age) {name age})"))
        #expect(erased(person).take(2).count == 1)
    }
}

@Suite("function combinators")
struct FunctionCombinatorTests {
    @Test func composeFoldAndScan() {
        let describe = compose({ (n: Int) in n * 2 }, { "\($0)" })
        #expect(describe(21) == "42")

        let total = fold(+, 0)
        #expect([1, 2, 3].map(total) == [1, 3, 6])

        let steps = scan(+, 0)
        #expect([1, 2, 3].map { steps($0).previous } == [0, 1, 3])
    }

    @Test func latchStaysFalseAndStopsAsking() {
        var asked = 0
        let allSmall = latch { (n: Int) in asked += 1; return n < 3 }
        #expect([1, 2, 5, 1].map(allSmall) == [true, true, false, false])
        #expect(asked == 3)
    }

    @Test func splitAndCount() {
        let both = split([{ (n: Int) in n + 1 }, { $0 * 10 }])
        #expect(both(4) == [5, 40])

        let numbered = count(String.self)
        #expect(["a", "b"].map { numbered($0).index } == [0, 1])
    }

    @Test func combinatorsPlugIntoStreams() {
        let running = Answers([3, 1, 4]) |> fold(max, Int.min)
        #expect(Array(running) == [3, 3, 4])
    }
}
