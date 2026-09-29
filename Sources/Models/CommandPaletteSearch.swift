import Foundation

/// The groups a ⌘K result can belong to, in their canonical display order.
enum PaletteSection: Int, CaseIterable, Comparable, Hashable, Sendable {
    case jobs
    case folders
    case commands
    case settings
    case watchFolders
    case downloads

    static func < (lhs: PaletteSection, rhs: PaletteSection) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Header while the user is searching.
    var title: String {
        switch self {
        case .jobs: "Jobs"
        case .folders: "Folders"
        case .commands: "Commands"
        case .settings: "Settings"
        case .watchFolders: "Watch Folders"
        case .downloads: "Downloads"
        }
    }

    /// Header for the suggestions shown before anything is typed.
    var suggestionTitle: String {
        switch self {
        case .jobs: "Recent Jobs"
        case .commands: "Suggested Commands"
        default: title
        }
    }
}

/// Pure matching and ranking behind the ⌘K palette. Nothing here knows about
/// views, `AppModel`, or the file system, so it is unit-testable and cheap to
/// run on every keystroke over hundreds of jobs.
///
/// Every searchable string is folded once (`FoldedText`): case, accents, and
/// full-width forms are ignored, and word starts are recorded so word-prefix
/// and acronym matches need no per-query work. Matching is per whitespace
/// separated token and every token must match somewhere (title, keywords, or
/// subtitle); match ranges are offsets in the *original* string's Characters
/// so a view can emphasize them directly.
enum CommandPaletteSearch {
    // MARK: - Tuning

    /// Score bands. Bonuses inside a band stay below 1000 (and above -200) so
    /// a stronger kind of match always outranks a weaker one.
    private enum Tier {
        static let exact = 6000
        static let prefix = 5000
        static let wordPrefix = 4000
        static let acronym = 3000
        static let substring = 2000
        static let subsequence = 1000
    }

    /// Percent of a hit's score kept per field: a title hit beats the same
    /// hit on a keyword, which beats the same hit on the subtitle.
    private enum FieldWeight {
        static let title = 100
        static let keyword = 70
        static let subtitle = 45
    }

    private enum Fuzzy {
        static let match = 10
        static let wordStart = 14
        static let consecutive = 12
        static let gap = 2
        static let leadingCap = 10
    }

    static let maxTokens = 6
    static let maxTokenLength = 40
    /// Subsequence matching only runs on short fields; on a long path nearly
    /// any query is a subsequence, which would be noise.
    static let fuzzyTextLimit = 120

    struct Limits: Sendable, Equatable {
        var perSection: [PaletteSection: Int]
        var suggestionsPerSection: [PaletteSection: Int]
        var commandsOnlyCommands: Int

        static let standard = Limits(
            perSection: [.jobs: 8, .folders: 4, .commands: 8, .settings: 4, .watchFolders: 3, .downloads: 3],
            suggestionsPerSection: [.jobs: 5, .commands: 6],
            commandsOnlyCommands: 40
        )

        func cap(for section: PaletteSection) -> Int { perSection[section] ?? 5 }
        func suggestionCap(for section: PaletteSection) -> Int { suggestionsPerSection[section] ?? 0 }
    }

    // MARK: - Folded text

    /// A string reduced to what matching needs: one comparable key per
    /// Character of the original (so offsets map back 1:1) and the positions
    /// where a word starts.
    struct FoldedText: Sendable, Equatable {
        let keys: [UInt32]
        let wordStarts: [Bool]
        let wordCount: Int

        var count: Int { keys.count }

        init(_ string: String) {
            var keys: [UInt32] = []
            var starts: [Bool] = []
            keys.reserveCapacity(string.utf8.count)
            starts.reserveCapacity(string.utf8.count)
            var words = 0
            var previous: Character?
            for character in string {
                keys.append(CommandPaletteSearch.foldedKey(character))
                let startsWord = CommandPaletteSearch.isWordStart(character, after: previous)
                starts.append(startsWord)
                if startsWord { words += 1 }
                previous = character
            }
            self.keys = keys
            self.wordStarts = starts
            self.wordCount = words
        }

        static func keys(of string: String) -> [UInt32] {
            string.map { CommandPaletteSearch.foldedKey($0) }
        }
    }

    /// One comparable value per Character: lowercased, accent-stripped, and
    /// width-folded. ASCII, kana, CJK, and Hangul take a fast path that never
    /// calls into Foundation; everything else is folded by Foundation.
    static func foldedKey(_ character: Character) -> UInt32 {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        if scalars.count == 1 {
            let value = first.value
            switch value {
            case 0x41...0x5A:
                return value + 0x20
            case 0x00...0x7F:
                return value
            case 0xFF01...0xFF5E:
                // Full-width ASCII variants (common in Japanese file names).
                let ascii = value - 0xFEE0
                return (0x41...0x5A).contains(ascii) ? ascii + 0x20 : ascii
            case 0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF:
                return value
            default:
                break
            }
        }
        let folded = String(character)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let foldedScalars = folded.unicodeScalars
        if foldedScalars.count == 1, let only = foldedScalars.first { return only.value }
        if foldedScalars.isEmpty { return first.value }
        // Several scalars (for example "ß" -> "ss", or a Hangul syllable
        // decomposed): a hash with the top bit set can never collide with a
        // single-scalar key, which is always below 0x110000.
        var hash: UInt32 = 2_166_136_261
        for scalar in foldedScalars {
            hash = (hash ^ scalar.value) &* 16_777_619
        }
        return hash | 0x8000_0000
    }

    /// A word starts after any separator, at the first character, and at a
    /// lower-to-upper camelCase step. Separators never start a word.
    static func isWordStart(_ character: Character, after previous: Character?) -> Bool {
        guard character.isLetter || character.isNumber else { return false }
        guard let previous else { return true }
        if !(previous.isLetter || previous.isNumber) { return true }
        return previous.isLowercase && character.isUppercase
    }

    // MARK: - Query

    struct Query: Equatable, Sendable {
        enum Scope: Sendable, Equatable {
            case everything
            /// The text began with ">": only commands are searched.
            case commands
        }

        let scope: Scope
        /// What was typed after the scope prefix, trimmed.
        let text: String
        let tokens: [[UInt32]]

        var isEmpty: Bool { tokens.isEmpty }

        init(_ raw: String) {
            var body = Substring(raw).drop(while: \.isWhitespace)
            var scope = Scope.everything
            if let first = body.first, first == ">" || first == "＞" {
                scope = .commands
                body = body.dropFirst()
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            self.scope = scope
            self.text = trimmed
            self.tokens =
                trimmed
                .split(whereSeparator: \.isWhitespace)
                .prefix(CommandPaletteSearch.maxTokens)
                .map { FoldedText.keys(of: String($0.prefix(CommandPaletteSearch.maxTokenLength))) }
        }
    }

    // MARK: - Items and results

    /// One searchable thing. Fold work happens here, once, not per keystroke.
    struct Item: Identifiable, Sendable {
        let id: String
        let section: PaletteSection
        let title: String
        let subtitle: String
        let keywords: [String]
        /// Disabled items are still searchable but rank after enabled ones.
        var isEnabled: Bool
        /// Added to every score for this item (a small negative sinks archived jobs).
        var bias: Int
        /// Non-nil = offered while the query is empty; lower comes first.
        var suggestionRank: Int?

        fileprivate let foldedTitle: FoldedText
        fileprivate let foldedSubtitle: FoldedText
        fileprivate let foldedKeywords: [FoldedText]

        init(
            id: String,
            section: PaletteSection,
            title: String,
            subtitle: String = "",
            keywords: [String] = [],
            isEnabled: Bool = true,
            bias: Int = 0,
            suggestionRank: Int? = nil
        ) {
            self.id = id
            self.section = section
            self.title = title
            self.subtitle = subtitle
            self.keywords = keywords
            self.isEnabled = isEnabled
            self.bias = bias
            self.suggestionRank = suggestionRank
            self.foldedTitle = FoldedText(title)
            self.foldedSubtitle = FoldedText(subtitle)
            self.foldedKeywords = keywords.map(FoldedText.init)
        }
    }

    struct Match: Identifiable, Equatable, Sendable {
        /// The matched item's id.
        let id: String
        /// Position of the item in the array that was searched.
        let itemIndex: Int
        let section: PaletteSection
        let isEnabled: Bool
        let score: Int
        /// Character offsets into the item's title / subtitle.
        let titleRanges: [Range<Int>]
        let subtitleRanges: [Range<Int>]
        /// The keyword that carried the match when neither the title nor the
        /// subtitle did, so a row can say why it is shown ("whisper" finds
        /// Models). Nil for title and subtitle matches and for suggestions.
        var matchedKeyword: String?
    }

    struct SectionResult: Equatable, Sendable {
        let section: PaletteSection
        /// Capped, best first.
        let matches: [Match]
        /// How many items matched before the cap.
        let totalMatches: Int
    }

    // MARK: - Entry points

    /// Results for any query: suggestions when nothing is typed, every command
    /// for a bare ">", otherwise ranked matches grouped by section.
    static func results(for query: Query, in items: [Item], limits: Limits = .standard) -> [SectionResult] {
        if query.isEmpty {
            return query.scope == .commands ? allCommands(in: items, limits: limits) : suggestions(in: items, limits: limits)
        }
        return search(query, in: items, limits: limits)
    }

    static func search(_ query: Query, in items: [Item], limits: Limits = .standard) -> [SectionResult] {
        guard !query.isEmpty else { return [] }
        var matchesBySection: [PaletteSection: [Match]] = [:]
        for (index, item) in items.enumerated() {
            if query.scope == .commands, item.section != .commands { continue }
            guard let match = match(item, at: index, query: query) else { continue }
            matchesBySection[item.section, default: []].append(match)
        }
        return assemble(matchesBySection, limits: limits, commandsOnly: query.scope == .commands)
    }

    /// What the palette offers before anything is typed: items with a
    /// suggestion rank, enabled only, in rank order.
    static func suggestions(in items: [Item], limits: Limits = .standard) -> [SectionResult] {
        var picked: [PaletteSection: [(rank: Int, index: Int)]] = [:]
        for (index, item) in items.enumerated() {
            guard item.isEnabled, let rank = item.suggestionRank else { continue }
            picked[item.section, default: []].append((rank, index))
        }
        var results: [SectionResult] = []
        for section in PaletteSection.allCases {
            guard var entries = picked[section], !entries.isEmpty else { continue }
            entries.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }
            let cap = limits.suggestionCap(for: section)
            guard cap > 0 else { continue }
            let matches = entries.prefix(cap).map { entry in
                Match(
                    id: items[entry.index].id,
                    itemIndex: entry.index,
                    section: section,
                    isEnabled: true,
                    score: 0,
                    titleRanges: [],
                    subtitleRanges: []
                )
            }
            results.append(SectionResult(section: section, matches: matches, totalMatches: entries.count))
        }
        return results
    }

    /// A bare ">" lists every command, runnable ones first, in inventory order.
    static func allCommands(in items: [Item], limits: Limits = .standard) -> [SectionResult] {
        var matches: [Match] = []
        for (index, item) in items.enumerated() where item.section == .commands {
            matches.append(
                Match(
                    id: item.id,
                    itemIndex: index,
                    section: .commands,
                    isEnabled: item.isEnabled,
                    score: 0,
                    titleRanges: [],
                    subtitleRanges: []
                )
            )
        }
        guard !matches.isEmpty else { return [] }
        let ordered = matches.filter(\.isEnabled) + matches.filter { !$0.isEnabled }
        return [
            SectionResult(
                section: .commands,
                matches: Array(ordered.prefix(limits.commandsOnlyCommands)),
                totalMatches: ordered.count
            )
        ]
    }

    // MARK: - Ranking

    private static func assemble(
        _ matchesBySection: [PaletteSection: [Match]],
        limits: Limits,
        commandsOnly: Bool
    ) -> [SectionResult] {
        var ranked: [(result: SectionResult, priority: Int)] = []
        for (section, unsorted) in matchesBySection where !unsorted.isEmpty {
            let sorted = unsorted.sorted { lhs, rhs in
                if lhs.isEnabled != rhs.isEnabled { return lhs.isEnabled }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.itemIndex < rhs.itemIndex
            }
            let cap = commandsOnly && section == .commands ? limits.commandsOnlyCommands : limits.cap(for: section)
            let result = SectionResult(section: section, matches: Array(sorted.prefix(cap)), totalMatches: sorted.count)
            // A section is as relevant as its best runnable hit; sections that
            // only hold disabled commands sink below everything else.
            let top = sorted[0]
            ranked.append((result, top.isEnabled ? top.score : top.score - 100_000))
        }
        ranked.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.result.section < rhs.result.section
        }
        return ranked.map(\.result)
    }

    private struct Hit {
        var score: Int
        var ranges: [Range<Int>]
    }

    private static func match(_ item: Item, at index: Int, query: Query) -> Match? {
        var total = item.bias
        var titleRanges: [Range<Int>] = []
        var subtitleRanges: [Range<Int>] = []
        var matchedKeyword: String?

        for token in query.tokens {
            let titleHit = hit(for: token, in: item.foldedTitle, kind: .title)
            let subtitleHit = hit(for: token, in: item.foldedSubtitle, kind: .subtitle)
            var keywordScore: Int?
            var keywordPosition: Int?
            for (position, keyword) in item.foldedKeywords.enumerated() {
                if let keywordHit = hit(for: token, in: keyword, kind: .keyword) {
                    let scaled = keywordHit.score * FieldWeight.keyword / 100
                    if scaled > (keywordScore ?? Int.min) {
                        keywordScore = scaled
                        keywordPosition = position
                    }
                }
            }

            let titleScore = titleHit.map { $0.score * FieldWeight.title / 100 }
            let subtitleScore = subtitleHit.map { $0.score * FieldWeight.subtitle / 100 }
            guard let best = [titleScore, keywordScore, subtitleScore].compactMap({ $0 }).max() else { return nil }
            total += best

            if matchedKeyword == nil, let keywordScore, let keywordPosition, keywordScore == best,
                (titleScore ?? Int.min) < best, (subtitleScore ?? Int.min) < best
            {
                matchedKeyword = item.keywords[keywordPosition]
            }

            // Emphasize only where the row really matched. A scattered fuzzy
            // title hit that lost to a keyword would highlight characters
            // that have nothing to do with why the row is shown.
            if let titleHit, let titleScore, titleHit.score >= Tier.substring - 200 || titleScore == best {
                titleRanges.append(contentsOf: titleHit.ranges)
            }
            if let subtitleHit {
                subtitleRanges.append(contentsOf: subtitleHit.ranges)
            }
        }

        return Match(
            id: item.id,
            itemIndex: index,
            section: item.section,
            isEnabled: item.isEnabled,
            score: total,
            titleRanges: mergeRanges(titleRanges),
            subtitleRanges: mergeRanges(subtitleRanges),
            matchedKeyword: matchedKeyword
        )
    }

    /// Sorted, non-overlapping ranges; touching ranges are joined.
    static func mergeRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        guard ranges.count > 1 else { return ranges }
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private enum FieldKind {
        case title
        case keyword
        case subtitle

        var allowsAcronym: Bool { self != .subtitle }
        var allowsFuzzy: Bool { self != .subtitle }
        /// Status and path text is long and generic: a mid-word hit on one or
        /// two letters would make nearly every job match, so those need
        /// a word start or a longer token.
        var minSubstringLength: Int { self == .subtitle ? 3 : 1 }
    }

    /// The best way `token` matches `field`, strongest kind first.
    private static func hit(for token: [UInt32], in field: FoldedText, kind: FieldKind) -> Hit? {
        let allowsAcronym = kind.allowsAcronym
        let allowsFuzzy = kind.allowsFuzzy
        let n = field.count
        let m = token.count
        guard m > 0, n >= m else { return nil }
        let keys = field.keys

        if matches(keys, token, at: 0) {
            if n == m { return Hit(score: Tier.exact, ranges: [0..<n]) }
            return Hit(score: Tier.prefix + 500 * m / n, ranges: [0..<m])
        }

        var wordIndex = 0
        var index = 1
        while index <= n - m {
            if field.wordStarts[index] {
                wordIndex += 1
                if matches(keys, token, at: index) {
                    let bonus = 300 * m / n - min(wordIndex * 20, 200)
                    return Hit(score: Tier.wordPrefix + bonus, ranges: [index..<(index + m)])
                }
            }
            index += 1
        }

        if allowsAcronym, m >= 2, field.wordCount >= m, let positions = acronymPositions(token, in: field) {
            let bonus = 300 * m / field.wordCount - min(positions[0] * 15, 150)
            return Hit(score: Tier.acronym + bonus, ranges: positions.map { $0..<($0 + 1) })
        }

        if m >= kind.minSubstringLength, let position = firstIndex(of: token, in: keys, from: 1) {
            let bonus = 300 * m / n - min(position * 3, 200)
            return Hit(score: Tier.substring + bonus, ranges: [position..<(position + m)])
        }

        if allowsFuzzy, m >= 2, n <= fuzzyTextLimit {
            return fuzzyHit(for: token, in: field)
        }
        return nil
    }

    private static func matches(_ keys: [UInt32], _ token: [UInt32], at start: Int) -> Bool {
        guard start >= 0, start + token.count <= keys.count else { return false }
        for offset in 0..<token.count where keys[start + offset] != token[offset] {
            return false
        }
        return true
    }

    private static func firstIndex(of token: [UInt32], in keys: [UInt32], from start: Int) -> Int? {
        guard token.count <= keys.count else { return nil }
        var index = start
        while index <= keys.count - token.count {
            if matches(keys, token, at: index) { return index }
            index += 1
        }
        return nil
    }

    /// Word starts that spell `token`, in order ("afu" -> Add From URL).
    private static func acronymPositions(_ token: [UInt32], in field: FoldedText) -> [Int]? {
        var positions: [Int] = []
        positions.reserveCapacity(token.count)
        var cursor = 0
        for key in token {
            var found: Int?
            var index = cursor
            while index < field.count {
                if field.wordStarts[index], field.keys[index] == key {
                    found = index
                    break
                }
                index += 1
            }
            guard let position = found else { return nil }
            positions.append(position)
            cursor = position + 1
        }
        return positions
    }

    /// Best in-order, possibly gapped match, preferring consecutive runs and
    /// word starts. O(token x text) with a running maximum for the gap term.
    private static func fuzzyHit(for token: [UInt32], in field: FoldedText) -> Hit? {
        let n = field.count
        let m = token.count
        let keys = field.keys

        // Cheap reject: the token has to be a subsequence at all.
        var cursor = 0
        for key in keys where cursor < m && key == token[cursor] {
            cursor += 1
        }
        guard cursor == m else { return nil }

        let impossible = Int.min / 4
        var best = [Int](repeating: impossible, count: m * n)
        var from = [Int](repeating: -1, count: m * n)

        for i in 0..<m {
            // Max over k <= j-2 of (best[i-1][k] + gap * k): the linear gap
            // penalty factors into a term per k and a term per j.
            var carry = impossible
            var carryFrom = -1
            for j in 0..<n {
                if i > 0, j >= 2 {
                    let earlier = best[(i - 1) * n + (j - 2)]
                    if earlier > impossible {
                        let candidate = earlier + Fuzzy.gap * (j - 2)
                        if candidate > carry {
                            carry = candidate
                            carryFrom = j - 2
                        }
                    }
                }
                guard keys[j] == token[i] else { continue }
                var gain = Fuzzy.match
                if field.wordStarts[j] { gain += Fuzzy.wordStart }
                if i == 0 {
                    best[j] = gain - min(j, Fuzzy.leadingCap)
                    continue
                }
                var choice = impossible
                var choiceFrom = -1
                if j >= 1 {
                    let adjacent = best[(i - 1) * n + (j - 1)]
                    if adjacent > impossible {
                        choice = adjacent + Fuzzy.consecutive
                        choiceFrom = j - 1
                    }
                }
                if carry > impossible {
                    let viaGap = carry - Fuzzy.gap * (j - 1)
                    if viaGap > choice {
                        choice = viaGap
                        choiceFrom = carryFrom
                    }
                }
                guard choice > impossible else { continue }
                best[i * n + j] = choice + gain
                from[i * n + j] = choiceFrom
            }
        }

        var endIndex = -1
        var endScore = impossible
        for j in 0..<n where best[(m - 1) * n + j] > endScore {
            endScore = best[(m - 1) * n + j]
            endIndex = j
        }
        guard endIndex >= 0 else { return nil }

        var positions = [Int](repeating: 0, count: m)
        var j = endIndex
        for i in stride(from: m - 1, through: 0, by: -1) {
            positions[i] = j
            if i > 0 { j = from[i * n + j] }
        }
        // A match smeared across the whole field says nothing.
        guard positions[m - 1] - positions[0] + 1 <= m * 3 + 6 else { return nil }

        let ceiling = m * (Fuzzy.match + Fuzzy.wordStart + Fuzzy.consecutive)
        let quality = max(0, min(endScore, ceiling)) * 700 / ceiling
        return Hit(score: Tier.subsequence + quality, ranges: positions.map { $0..<($0 + 1) })
    }
}
