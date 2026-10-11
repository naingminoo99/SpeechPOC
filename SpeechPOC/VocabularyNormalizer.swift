import Foundation

/// Post-processes transcripts against the vocabulary, ported from cloud/whisper-server/vocab.py so the
/// on-device engines get the same clean-up as Whisper:
/// 1. Known mishearings → canonical term (`MBS_NORMALIZATIONS`).
/// 2. Fuzzy snapping of near-miss words to vocabulary terms (Levenshtein, capped by word length),
///    never touching common English words.
///
/// It also picks the best of the recognizer's alternative transcriptions: the one that contains the
/// most vocabulary terms.
struct VocabularyNormalizer {

    private static let normalizations: [(variants: String, canonical: String)] = [
        ("paizar / paisa / piza", "Paiza"),
        ("yamazake / yamasaki", "Yamazaki"),
        ("hi-bee-key / hibikey", "Hibiki"),
        ("don peri-yon / dom perinion", "Dom Pérignon"),
        ("voo cliquot / voov click-oh", "Veuve Clicquot"),
        ("wakku gin / waku gin / waku jin / waku-jin / wakujin", "Waku Ghin"),
        ("yad-bert / yardberg", "Yardbird"),
        ("see la vee / sila vie", "CÉ LA VI"),
        ("mo-ay / mo-ette", "Moët"),
        ("pu-air / pu-ehr", "Pu'er"),
        ("tee-gwan-yin", "Tieguanyin"),
        ("long-jing / long ching", "Longjing"),
        ("perry-air / perier", "Perrier"),
        ("san pellegreeno", "San Pellegrino"),
        ("mcallan / makallan", "Macallan"),
        ("spaggoggo / spagogo / spa-go-go", "Spago"),
        ("wakudaaa / wakudada", "Wakuda"),
        ("sandz sweet / sand sweet / sands sweet / sandz suite", "Sands Suite")
    ]

    private static let neverRewrite: Set<String> = Set("""
    i a an the and but or so if for to of he she we they it his her their our my
    this that these those there here is are was were be been being have has had
    do does did will would should could can may might in on at with by from as
    about please thank thanks hello hi good yes no ok okay always never sometimes
    today tomorrow tonight morning evening afternoon night service butler guest
    hotel room suite prefer prefers preferred like likes liked love loves want
    wants wanted need needs needed enjoy enjoys request requests requested
    arrival arriving arrives check checks checked checkin checkout welcome
    welcomes welcomed better best free fresh water waiter waters drink drinks
    meal meals breakfast lunch dinner pillow pillows flower flowers curtain
    curtains blanket towel towels bottle bottles table chair sofa shower bath
    allergic allergy allergies avoid avoids vegetarian vegan halal kosher
    booking booked ordered order orders prepare prepared arrange arranged
    remind reminder confirm confirmed schedule scheduled family friend friends
    wife husband daughter son madam mister miss doctor about around before
    after during between under over very really quite just also still then
    than when where which while whose people person time times year years
    month months week weeks day days hour hours minute minutes clock
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let tokenBlocklist: Set<String> = [
        "bay", "sky", "sea", "cut", "tea", "bar", "cup", "club", "room",
        "suite", "street", "la", "vi", "ce", "don", "san", "old", "new",
        "top", "rise", "grey", "earl"
    ]

    private static let normalizationPatterns: [(NSRegularExpression, String)] = {
        var patterns: [(NSRegularExpression, String)] = []
        for (variants, canonical) in normalizations {
            for variant in variants.split(separator: "/") {
                let parts = variant.trimmingCharacters(in: .whitespaces)
                    .split(whereSeparator: { $0 == " " || $0 == "-" })
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                guard !parts.isEmpty else { continue }
                let pattern = "(?<!\\w)" + parts.joined(separator: "[\\s-]+") + "(?!\\w)"
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    patterns.append((regex, canonical))
                }
            }
        }
        return patterns.sorted { $0.0.pattern.count > $1.0.pattern.count }
    }()

    private static let wordRegex = try! NSRegularExpression(pattern: "[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ'’-]*")

    private let terms: [String]
    /// First letter → [(lowercased, canonical)] for whole single-word terms and long parts of phrases.
    private let fuzzyIndex: [Character: [(String, String)]]

    init(terms: [String]) {
        self.terms = terms
        var index: [Character: [(String, String)]] = [:]
        var seen: Set<String> = []
        func add(_ word: String) {
            let lower = word.lowercased()
            guard lower.count >= 4, !seen.contains(lower), !Self.tokenBlocklist.contains(lower), let first = lower.first else { return }
            seen.insert(lower)
            index[first, default: []].append((lower, word))
        }
        for term in terms {
            if term.contains(" ") {
                term.split(separator: " ").filter { $0.count >= 5 }.forEach { add(String($0)) }
            } else {
                add(term)
            }
        }
        fuzzyIndex = index
    }

    /// Applies known mishearings, then fuzzy snapping.
    func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var output = text
        for (regex, canonical) in Self.normalizationPatterns {
            let range = NSRange(output.startIndex..., in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: canonical))
        }
        return fuzzyCorrect(output)
    }

    /// Of the primary transcription and its alternatives, returns the one mentioning the most
    /// vocabulary terms (the primary wins ties).
    func bestCandidate(primary: String, alternatives: [String]) -> String {
        guard !terms.isEmpty, !alternatives.isEmpty else { return primary }
        var best = primary
        var bestScore = termHits(in: primary)
        for alternative in alternatives where alternative != primary {
            let score = termHits(in: alternative)
            if score > bestScore {
                best = alternative
                bestScore = score
            }
        }
        return best
    }

    private func termHits(in text: String) -> Int {
        terms.filter { term in
            let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: term) + "(?!\\w)"
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) != nil
        }.count
    }

    private func fuzzyCorrect(_ text: String) -> String {
        guard !fuzzyIndex.isEmpty else { return text }
        var memo: [String: String?] = [:]
        let nsText = text as NSString
        var output = ""
        var cursor = 0
        for match in Self.wordRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            output += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let word = nsText.substring(with: match.range)
            let lower = word.lowercased()
            let replacement: String?
            if let cached = memo[lower] {
                replacement = cached
            } else {
                replacement = fuzzyMatch(lower)
                memo[lower] = replacement
            }
            output += replacement ?? word
            cursor = match.range.location + match.range.length
        }
        output += nsText.substring(from: cursor)
        return output
    }

    private func fuzzyMatch(_ token: String) -> String? {
        guard token.count >= 4, !Self.neverRewrite.contains(token), let first = token.first else { return nil }
        var best: String?
        var bestDistance = Int.max
        for (candidate, canonical) in fuzzyIndex[first] ?? [] {
            if candidate == token { return nil }
            let cap = Self.distanceCap(max(token.count, candidate.count))
            let distance = Self.levenshtein(Array(token), Array(candidate), cap: cap)
            if distance <= cap, distance < bestDistance {
                best = canonical
                bestDistance = distance
                if distance == 1 { break }
            }
        }
        return best
    }

    private static func distanceCap(_ length: Int) -> Int {
        length <= 6 ? 1 : (length <= 10 ? 2 : 3)
    }

    /// Levenshtein distance with an early exit once every cell in a row exceeds `cap`.
    private static func levenshtein(_ a: [Character], _ b: [Character], cap: Int) -> Int {
        if abs(a.count - b.count) > cap { return cap + 1 }
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            var rowMin = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > cap { return cap + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
