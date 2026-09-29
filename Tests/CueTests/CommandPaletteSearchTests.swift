import Foundation
import Testing

@testable import Cue

struct CommandPaletteSearchTests {
    typealias Search = CommandPaletteSearch

    // MARK: - Helpers

    private func command(
        _ title: String,
        keywords: [String] = [],
        enabled: Bool = true,
        rank: Int? = nil,
        bias: Int = 0
    ) -> Search.Item {
        Search.Item(
            id: "cmd:\(title)",
            section: .commands,
            title: title,
            keywords: keywords,
            isEnabled: enabled,
            bias: bias,
            suggestionRank: rank
        )
    }

    private func job(
        _ title: String,
        subtitle: String = "",
        rank: Int? = nil,
        bias: Int = 0,
        id: String? = nil
    ) -> Search.Item {
        Search.Item(
            id: id ?? "job:\(title)",
            section: .jobs,
            title: title,
            subtitle: subtitle,
            bias: bias,
            suggestionRank: rank
        )
    }

    private func run(_ text: String, _ items: [Search.Item]) -> [Search.SectionResult] {
        Search.results(for: Search.Query(text), in: items)
    }

    private func ids(_ results: [Search.SectionResult], _ section: PaletteSection) -> [String] {
        results.first(where: { $0.section == section })?.matches.map(\.id) ?? []
    }

    private func match(_ text: String, _ item: Search.Item) -> Search.Match? {
        run(text, [item]).first?.matches.first
    }

    // MARK: - Query parsing

    @Test func queryParsesScopeTextAndTokens() {
        let plain = Search.Query("  stop   jobs ")
        #expect(plain.scope == .everything)
        #expect(plain.text == "stop   jobs")
        #expect(plain.tokens.count == 2)
        #expect(!plain.isEmpty)

        let scoped = Search.Query(" >  export  log ")
        #expect(scoped.scope == .commands)
        #expect(scoped.text == "export  log")
        #expect(scoped.tokens.count == 2)

        let fullWidth = Search.Query("＞stop")
        #expect(fullWidth.scope == .commands)
        #expect(fullWidth.tokens.count == 1)

        let bare = Search.Query(">")
        #expect(bare.scope == .commands)
        #expect(bare.isEmpty)

        let blank = Search.Query("   \n ")
        #expect(blank.scope == .everything)
        #expect(blank.isEmpty)

        let inner = Search.Query("a>b")
        #expect(inner.scope == .everything)
        #expect(inner.tokens.count == 1)
    }

    @Test func queryCapsTokenCountAndLength() {
        let many = Search.Query((0..<20).map { "t\($0)" }.joined(separator: " "))
        #expect(many.tokens.count == Search.maxTokens)
        let long = Search.Query(String(repeating: "a", count: 500))
        #expect(long.tokens.first?.count == Search.maxTokenLength)
    }

    // MARK: - Folding

    @Test func foldingIgnoresCaseAccentsAndWidth() {
        #expect(Search.foldedKey("É") == Search.foldedKey("e"))
        #expect(Search.foldedKey("é") == Search.foldedKey("E"))
        #expect(Search.foldedKey("ñ") == Search.foldedKey("n"))
        #expect(Search.foldedKey("Ａ") == Search.foldedKey("a"))
        #expect(Search.foldedKey("７") == Search.foldedKey("7"))
        #expect(Search.foldedKey("A") == Search.foldedKey("a"))
        #expect(Search.foldedKey("a") != Search.foldedKey("b"))
        // A decomposed "e" + combining acute is one Character and folds the same.
        #expect(Search.foldedKey(Character("e\u{0301}")) == Search.foldedKey("e"))
    }

    @Test func foldedTextRecordsWordStarts() {
        let folded = Search.FoldedText("Add from URL… v2.mov")
        #expect(folded.count == 20)
        // A(0) f(4) U(9) v(14) m(17). The "2" follows a letter, so "v2" is one
        // word; the period separates it from "mov".
        let starts = folded.wordStarts.enumerated().filter(\.element).map(\.offset)
        #expect(starts == [0, 4, 9, 14, 17])
        #expect(folded.wordCount == 5)

        let camel = Search.FoldedText("exportLog")
        #expect(camel.wordStarts.enumerated().filter(\.element).map(\.offset) == [0, 6])
    }

    @Test func diacriticsAndCaseDoNotBlockMatches() throws {
        let cafe = job("Café Résumé")
        let hit = try #require(match("cafe resume", cafe))
        #expect(hit.titleRanges == [0..<4, 5..<11])
        #expect(match("CAFÉ", cafe) != nil)
        #expect(match("résumé", cafe) != nil)
        #expect(match("cafe", job("Cafe Latte")) != nil)
        #expect(match("café", job("Cafe Latte")) != nil)

        let decomposed = job("Cafe\u{0301} Noir")
        let decomposedHit = try #require(match("cafe noir", decomposed))
        // Ranges count Characters, so a combining mark does not shift them.
        #expect(decomposedHit.titleRanges == [0..<4, 5..<9])
    }

    @Test func fullWidthAndCJKTitlesAreSearchable() throws {
        let hit = try #require(match("abc", job("ＡＢＣ 会議 2024")))
        #expect(hit.titleRanges == [0..<3])
        let cjk = try #require(match("会議", job("会議 2024 録画")))
        #expect(cjk.titleRanges == [0..<2])
        #expect(match("録画", job("会議 2024 録画")) != nil)
    }

    // MARK: - Tiers

    @Test func strongerKindsOfMatchAlwaysOutrankWeakerOnes() {
        let items = [
            job("Long Gap"),  // subsequence: l-o-g
            job("Catalog"),  // substring
            job("Lots Of Games"),  // acronym
            job("Export Log…"),  // word prefix
            job("Logbook"),  // prefix
            job("Log"),  // exact
        ]
        let results = run("log", items)
        #expect(
            ids(results, .jobs) == [
                "job:Log", "job:Logbook", "job:Export Log…", "job:Lots Of Games", "job:Catalog", "job:Long Gap",
            ]
        )
    }

    @Test func earlierWordsAndShorterTitlesScoreHigher() {
        let items = [
            job("Interview with Sam"),
            job("Sam Interview"),
            job("Interview with Samantha"),
        ]
        let results = run("sam", items)
        // "Sam Interview" is a prefix hit; of the two word-prefix hits the
        // shorter title covers more of itself.
        #expect(ids(results, .jobs) == ["job:Sam Interview", "job:Interview with Sam", "job:Interview with Samantha"])
    }

    @Test func acronymMatchesWordStartsInOrder() throws {
        let addFromURL = command("Add from URL…")
        let hit = try #require(match("afu", addFromURL))
        #expect(hit.titleRanges == [0..<1, 4..<5, 9..<10])
        #expect(match("fua", addFromURL) == nil)
        // Two letters is enough for an acronym of a multi-word title.
        #expect(match("sa", command("Start All"))?.titleRanges == [0..<1, 6..<7])
    }

    @Test func subsequenceMatchesScatteredLetters() throws {
        let hit = try #require(match("trns", command("Transcribe")))
        #expect(hit.titleRanges == [0..<1, 1..<2, 3..<4, 4..<5] || hit.titleRanges == [0..<2, 3..<5])
        #expect(match("tzns", command("Transcribe")) == nil)
        #expect(match("zzz", command("Transcribe")) == nil)
    }

    @Test func fuzzyMatchingRejectsSmearedAndOverlongText() {
        let smeared = "a" + String(repeating: "x", count: 30) + "e"
        #expect(match("ae", job(smeared)) == nil)

        let atLimit = String(repeating: "ab", count: 50)  // 100 characters
        #expect(match("bb", job(atLimit)) != nil)
        let overLimit = String(repeating: "ab", count: 65)  // 130 characters
        #expect(match("bb", job(overLimit)) == nil)
    }

    @Test func aTokenLongerThanTheTextNeverMatches() {
        #expect(match("transcribing", command("Transcribe")) == nil)
    }

    // MARK: - Ranges

    @Test func prefixWordPrefixAndSubstringRanges() throws {
        #expect(try #require(match("tra", command("Transcribe"))).titleRanges == [0..<3])
        #expect(try #require(match("log", command("Export Log…"))).titleRanges == [7..<10])
        #expect(try #require(match("cat", job("Concatenate"))).titleRanges == [3..<6])
        #expect(try #require(match("transcribe", command("Transcribe"))).titleRanges == [0..<10])
    }

    @Test func multipleTokensMergeTouchingRanges() throws {
        let hit = try #require(match("ex log", command("Export Log…")))
        #expect(hit.titleRanges == [0..<2, 7..<10])

        let joined = try #require(match("ab cd", job("abcd")))
        #expect(joined.titleRanges == [0..<4])

        let overlapping = try #require(match("tra trans", command("Transcribe")))
        #expect(overlapping.titleRanges == [0..<5])
    }

    @Test func mergeRangesSortsAndJoins() {
        #expect(Search.mergeRanges([]) == [])
        #expect(Search.mergeRanges([3..<5]) == [3..<5])
        #expect(Search.mergeRanges([5..<7, 0..<2, 2..<3]) == [0..<3, 5..<7])
        #expect(Search.mergeRanges([0..<6, 2..<3]) == [0..<6])
    }

    @Test func keywordAndSubtitleMatchesDoNotHighlightTheTitle() throws {
        let settings = command("Open Settings…", keywords: ["preferences", "prefs"])
        let viaKeyword = try #require(match("prefs", settings))
        #expect(viaKeyword.titleRanges.isEmpty)
        #expect(viaKeyword.subtitleRanges.isEmpty)

        let podcast = job("Interview 04", subtitle: "Completed · ~/Movies/Podcasts")
        let viaPath = try #require(match("podcasts", podcast))
        #expect(viaPath.titleRanges.isEmpty)
        #expect(viaPath.subtitleRanges == [21..<29])
    }

    @Test func titleHighlightsKeepRealTitleHitsButDropLosingFuzzyOnes() throws {
        // "sett" is a prefix of a keyword and a word-prefix in the title; the
        // title still gets its emphasis because that hit is a real one.
        let settings = command("Open Settings…", keywords: ["settings"])
        let hit = try #require(match("sett", settings))
        #expect(hit.titleRanges == [5..<9])
    }

    // MARK: - Fields

    @Test func keywordsMatchWithoutAppearingInTheTitle() {
        let item = command("Open Settings…", keywords: ["preferences", "options"])
        #expect(match("opt", item) != nil)
        #expect(match("preferences", item) != nil)
        #expect(match("volume", item) == nil)
    }

    @Test func titleHitsOutrankKeywordAndSubtitleHits() {
        let items = [
            Search.Item(id: "sub", section: .jobs, title: "Unrelated", subtitle: "Completed · ~/Exports"),
            Search.Item(id: "key", section: .jobs, title: "Another", keywords: ["export"]),
            Search.Item(id: "title", section: .jobs, title: "Export notes"),
        ]
        #expect(ids(run("export", items), .jobs) == ["title", "key", "sub"])
    }

    @Test func shortMidWordSubtitleHitsAreIgnoredButWordStartsCount() {
        let podcast = job("Interview 04", subtitle: "Completed · ~/Movies/Podcasts")
        // "ov" sits inside "Movies": too weak a signal on a long path.
        #expect(match("ov", podcast) == nil)
        // "po" starts the "Podcasts" word.
        #expect(match("po", podcast) != nil)
        // Three letters inside a word are specific enough.
        #expect(match("dca", podcast) != nil)
    }

    @Test func everyTokenMustMatchSomewhere() {
        let items = [command("Stop All Jobs"), command("Stop Watching"), command("Export Log…")]
        #expect(ids(run("stop jobs", items), .commands) == ["cmd:Stop All Jobs"])
        #expect(run("stop zzz", items).isEmpty)
        // Tokens may match different fields.
        let withPath = [job("Weekly Sync", subtitle: "Failed · ~/Meetings")]
        #expect(ids(run("weekly failed", withPath), .jobs) == ["job:Weekly Sync"])
    }

    // MARK: - Sections, caps, ordering

    @Test func disabledCommandsRankAfterEnabledOnes() {
        let items = [
            command("Stop All Jobs", enabled: false),  // best textual hit, but not runnable
            command("Backstop Report"),
            command("Stop Watching"),
        ]
        let results = run("stop", items)
        #expect(ids(results, .commands) == ["cmd:Stop Watching", "cmd:Backstop Report", "cmd:Stop All Jobs"])
        let last = results.first?.matches.last
        #expect(last?.isEnabled == false)
    }

    @Test func aSectionOfOnlyDisabledCommandsSinksBelowOtherSections() {
        let items = [
            command("Stop All Jobs", enabled: false),
            job("Stop Motion Clip"),
        ]
        let results = run("stop", items)
        #expect(results.map(\.section) == [.jobs, .commands])
    }

    @Test func sectionsAreOrderedByTheirBestHit() {
        let items = [
            job("Transcribe Demo"),
            command("Transcribe"),
            Search.Item(id: "pane", section: .settings, title: "Transcription", keywords: ["whisper"]),
        ]
        // All three prefix a title, but the ranking follows the best hit, not
        // the canonical section order: the shortest title (Transcribe) wins.
        let results = run("transcri", items)
        #expect(results.map(\.section) == [.commands, .settings, .jobs])
    }

    @Test func tiedSectionsFallBackToCanonicalOrder() {
        let items = [
            command("Alpha"),
            job("Alpha"),
        ]
        let results = run("alpha", items)
        #expect(results.map(\.section) == [.jobs, .commands])
    }

    @Test func perSectionCapsApplyAndReportTotals() throws {
        let items = (0..<12).map { job("Take \($0)") } + (0..<12).map { command("Take command \($0)") }
        let results = run("take", items)
        let jobs = try #require(results.first(where: { $0.section == .jobs }))
        let commands = try #require(results.first(where: { $0.section == .commands }))
        #expect(jobs.matches.count == Search.Limits.standard.cap(for: .jobs))
        #expect(jobs.totalMatches == 12)
        #expect(commands.matches.count == Search.Limits.standard.cap(for: .commands))
        #expect(commands.totalMatches == 12)
    }

    @Test func tiesKeepInventoryOrder() {
        let items = (0..<5).map { job("Take", id: "job:\($0)") }
        #expect(ids(run("take", items), .jobs) == (0..<5).map { "job:\($0)" })
        // Reversing the input reverses the tie order: the tie-break is the input position.
        #expect(ids(run("take", items.reversed()), .jobs) == (0..<5).reversed().map { "job:\($0)" })
    }

    @Test func resultsAreDeterministicAcrossRuns() {
        let items = (0..<80).map { job("Episode \($0 % 7) part \($0)") }
        let first = run("ep 3", items)
        for _ in 0..<3 { #expect(run("ep 3", items) == first) }
    }

    @Test func biasSinksArchivedJobsBelowEqualHits() {
        let items = [
            job("Take", bias: -500, id: "archived"),
            job("Take", id: "active"),
        ]
        #expect(ids(run("take", items), .jobs) == ["active", "archived"])
    }

    @Test func noMatchesReturnNothing() {
        let items = [job("Interview"), command("Transcribe")]
        #expect(run("qzxv", items).isEmpty)
        #expect(run(">qzxv", items).isEmpty)
    }

    // MARK: - Scope and empty query

    @Test func greaterThanScopesResultsToCommands() {
        let items = [
            job("Transcribe Demo"),
            command("Transcribe"),
            Search.Item(id: "pane", section: .settings, title: "Transcription"),
        ]
        let scoped = run(">transcri", items)
        #expect(scoped.map(\.section) == [.commands])
        #expect(ids(scoped, .commands) == ["cmd:Transcribe"])
        let open = run("transcri", items)
        #expect(open.count == 3)
    }

    @Test func aBareGreaterThanListsEveryCommandRunnableFirst() throws {
        let items = [
            command("Stop All Jobs", enabled: false),
            command("Add Files…"),
            job("Interview"),
            command("Transcribe", enabled: false),
            command("Export Log…"),
        ]
        let results = run(">", items)
        let section = try #require(results.first)
        #expect(results.count == 1)
        #expect(section.section == .commands)
        #expect(section.matches.map(\.id) == ["cmd:Add Files…", "cmd:Export Log…", "cmd:Stop All Jobs", "cmd:Transcribe"])
        #expect(section.totalMatches == 4)
        #expect(section.matches.map(\.isEnabled) == [true, true, false, false])
    }

    @Test func emptyQueryOffersRankedEnabledSuggestions() {
        var recentDisabled = command("Stop All Jobs", enabled: false, rank: 0)
        recentDisabled.isEnabled = false
        let items =
            [
                job("Older", rank: 2),
                job("Selected", rank: 0),
                job("Not suggested"),
                job("Newer", rank: 1),
                recentDisabled,
                command("Add Files…", rank: 1),
                command("Add from URL…", rank: 0),
                command("Hidden Command"),
            ]
        let results = run("", items)
        #expect(results.map(\.section) == [.jobs, .commands])
        #expect(ids(results, .jobs) == ["job:Selected", "job:Newer", "job:Older"])
        #expect(ids(results, .commands) == ["cmd:Add from URL…", "cmd:Add Files…"])
    }

    @Test func suggestionCapsApplyPerSection() throws {
        let jobItems = (0..<20).map { (index: Int) in job("Job \(index)", rank: index) }
        let commandItems = (0..<20).map { (index: Int) in command("Command \(index)", rank: index) }
        let items = jobItems + commandItems
        let results = run("  ", items)
        let jobs = try #require(results.first(where: { $0.section == .jobs }))
        let commands = try #require(results.first(where: { $0.section == .commands }))
        #expect(jobs.matches.count == Search.Limits.standard.suggestionCap(for: .jobs))
        #expect(jobs.totalMatches == 20)
        #expect(commands.matches.count == Search.Limits.standard.suggestionCap(for: .commands))
        // Suggestions carry no highlight ranges.
        #expect(jobs.matches.allSatisfy { $0.titleRanges.isEmpty && $0.subtitleRanges.isEmpty })
    }

    @Test func sectionTitlesAndOrderAreStable() {
        #expect(PaletteSection.allCases.map(\.title) == ["Jobs", "Commands", "Settings", "Watch Folders", "Downloads"])
        #expect(PaletteSection.allCases == PaletteSection.allCases.sorted())
        #expect(PaletteSection.jobs.suggestionTitle == "Recent Jobs")
        #expect(PaletteSection.commands.suggestionTitle == "Suggested Commands")
    }

    // MARK: - Robustness

    @Test func highlightRangesAreAlwaysValid() {
        var generator = SplitMix(seed: 0xC0FF_EE)
        let alphabet = Array("abcdefghij éñü ·-_/.~ABCDEF0123 会議".map(String.init))
        func randomText(_ length: Int) -> String {
            (0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] }.joined()
        }
        let items = (0..<300).map { index in
            Search.Item(
                id: "i\(index)",
                section: PaletteSection.allCases[index % PaletteSection.allCases.count],
                title: randomText(4 + index % 30),
                subtitle: randomText(index % 50),
                keywords: index % 3 == 0 ? [randomText(6)] : []
            )
        }
        let queries = (0..<150).map { _ in randomText(1 + Int(generator.next() % 5)) }
        for text in queries {
            let query = Search.Query(text)
            for section in Search.results(for: query, in: items) {
                for match in section.matches {
                    let item = items[match.itemIndex]
                    #expect(item.id == match.id)
                    for (ranges, count) in [(match.titleRanges, item.title.count), (match.subtitleRanges, item.subtitle.count)] {
                        var previousEnd = -1
                        for range in ranges {
                            #expect(range.lowerBound >= 0 && range.upperBound <= count && !range.isEmpty)
                            #expect(range.lowerBound > previousEnd || previousEnd == -1)
                            previousEnd = range.upperBound
                        }
                    }
                }
            }
        }
    }

    @Test func singleTokenHighlightsSpellTheToken() {
        var generator = SplitMix(seed: 42)
        let words = ["Transcribe", "Export Log…", "Add from URL…", "Stop All Jobs", "Résumé Draft 2024", "Weekly Sync", "Open Settings…"]
        let queries = ["t", "tr", "trn", "log", "afu", "sa", "resume", "wks", "set", "ops", "exp", "url", "jobs", "drft", "2024"]
        _ = generator.next()
        for title in words {
            let item = job(title)
            let folded = Search.FoldedText(title)
            for text in queries {
                let query = Search.Query(text)
                guard let hit = Search.results(for: query, in: [item]).first?.matches.first, !hit.titleRanges.isEmpty else { continue }
                let highlighted = hit.titleRanges.flatMap { Array(folded.keys[$0]) }
                #expect(highlighted == query.tokens[0], "\(text) on \(title)")
            }
        }
    }

    // MARK: - Performance smoke

    private func makeCorpus(jobs count: Int) -> [Search.Item] {
        let subjects = ["Interview", "Lecture", "Standup", "Podcast", "Keynote", "Webinar", "Rehearsal", "Demo"]
        let people = ["Sam", "Priya", "Ünal", "José", "Mei", "Olga", "Tariq", "Noor"]
        let statuses = ["Completed", "Transcribing", "Failed", "Queued", "Translating"]
        var items: [Search.Item] = []
        for index in 0..<count {
            let title = "\(subjects[index % subjects.count]) \(index) with \(people[(index / 3) % people.count])"
            let folder = "~/Movies/Season \(index % 12)/Episodes/Batch \(index / 50)"
            items.append(
                Search.Item(
                    id: "job:\(index)",
                    section: .jobs,
                    title: title,
                    subtitle: "\(statuses[index % statuses.count]) · \(folder)",
                    keywords: index % 4 == 0 ? ["mp4"] : []
                )
            )
        }
        for (offset, title) in ["Stop All Jobs", "Add Files…", "Add from URL…", "Export Log…", "Start All", "Transcribe", "Translate"].enumerated() {
            items.append(command(title, keywords: ["queue"], rank: offset))
        }
        return items
    }

    private func slowestQuery(_ queries: [String], in items: [Search.Item], repetitions: Int = 3) -> (String, Duration) {
        let clock = ContinuousClock()
        var slowest: (String, Duration) = ("", .zero)
        for text in queries {
            var best = Duration.seconds(10)
            for _ in 0..<repetitions {
                let query = Search.Query(text)
                let elapsed = clock.measure { _ = Search.results(for: query, in: items) }
                best = min(best, elapsed)
            }
            if best > slowest.1 { slowest = (text, best) }
        }
        return slowest
    }

    @Test func sixHundredJobsSearchWellUnderAKeystroke() {
        let items = makeCorpus(jobs: 600)
        let queries = [
            "i", "int", "interview", "interview 5", "ep season", "sam", "resume", "ünal", "prya", "stop", "afu", ">stop", "xqzv", "completed movies",
            "season 7 batch 3", "mp4",
        ]
        let (query, elapsed) = slowestQuery(queries, in: items)
        // A debug build on a busy machine is ~50x slower than release; the bound
        // only has to catch an accidental quadratic blow-up, not tune milliseconds.
        #expect(elapsed < .milliseconds(200), "slowest query \"\(query)\" took \(elapsed)")
    }

    @Test func searchScalesLinearlyToThousandsOfJobs() {
        let small = makeCorpus(jobs: 600)
        let large = makeCorpus(jobs: 6_000)
        let queries = ["interview", "ep season", "afu", "xqzv"]
        let smallCost = slowestQuery(queries, in: small).1
        let largeCost = slowestQuery(queries, in: large).1
        #expect(largeCost < .seconds(2), "6,000 jobs took \(largeCost)")
        // 10x the data must not cost anywhere near 100x the time.
        #expect(largeCost < max(smallCost * 40, .milliseconds(50)), "small \(smallCost), large \(largeCost)")
    }

    @Test func buildingItemsForSixHundredJobsIsCheap() {
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = makeCorpus(jobs: 600) }
        #expect(elapsed < .milliseconds(500), "building 600 items took \(elapsed)")
    }
}

/// Small deterministic generator so the randomized tests are reproducible.
private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
