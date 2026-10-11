import Foundation
import Speech

/// Domain knowledge used to train the on-device custom language model, mirroring
/// cloud/whisper-server/vocab.py.
///
/// Apple's guidance (WWDC23 "Customize on-device speech recognition" and the "Recognizing speech in
/// live audio" sample) is to train on phrases the way people actually say them, via templates with
/// word classes, rather than on isolated words, and to add X-SAMPA pronunciations for words the
/// recognizer has never seen.
enum VocabularyCatalog {

    /// Known terms grouped by how they're used in speech. Terms the user adds that aren't listed here
    /// fall into a generic class.
    static let classes: [String: [String]] = [
        "programme": ["Paiza Chairman", "Paiza Diamond", "Paiza", "Sands Lifestyle", "Sands Rewards Club", "SRC", "GRA"],
        "venue": [
            "Spago", "Cut", "Waku Ghin", "Wakuda", "Punjab Grill", "db Bistro", "Bread Street Kitchen", "Lavo",
            "Koma", "Origin Bar", "Yardbird", "Mott 32", "Adrift", "RISE", "CÉ LA VI", "Marquee", "Avenue",
            "Sampan", "Renku", "SkyPark", "ArtScience", "Shoppes", "Marina Bay Sands", "MBS", "Sands"
        ],
        "suite": ["Chairman Suite", "Premier Suite", "Orchid Suite", "Presidential Suite", "Sands Suite", "Club", "Deluxe"],
        "spirit": [
            "Yamazaki", "Hibiki", "Macallan", "Glenfiddich", "Glenmorangie", "Glenlivet", "Hennessy", "Rémy Martin",
            "Don Julio", "Patrón", "Johnnie Walker", "Chivas", "Bowmore"
        ],
        "champagne": ["Dom Pérignon", "Krug", "Veuve Clicquot", "Moët", "Bollinger", "Ruinart"],
        "water": ["Perrier", "Evian", "San Pellegrino", "Voss", "Fiji", "Acqua Panna"],
        "tea": ["Longjing", "Tieguanyin", "Oolong", "Pu'er", "Earl Grey", "TWG"],
        "coffee": ["Illy", "Nespresso"],
        "cigar": ["Cohiba", "Davidoff", "Montecristo"]
    ]

    /// Sentence templates per class; `count` is how many samples each template expands to.
    static let templates: [String: [(String, Int)]] = [
        "programme": [("a <programme> member", 4000), ("the guest is <programme>", 2000), ("<programme>", 2000)],
        "venue": [("a table at <venue>", 3000), ("dinner at <venue>", 3000), ("book <venue> for tonight", 2000), ("<venue>", 2000)],
        "suite": [("upgrade to the <suite>", 3000), ("staying in the <suite>", 2000)],
        "spirit": [("a glass of <spirit>", 3000), ("<spirit> on the rocks", 2000), ("a bottle of <spirit>", 2000), ("the guest prefers <spirit>", 2000)],
        "champagne": [("a bottle of <champagne>", 3000), ("<champagne> champagne", 2000), ("chilled <champagne>", 1000)],
        "water": [("the guest prefers <water>", 3000), ("a bottle of <water>", 2000)],
        "tea": [("a pot of <tea>", 3000), ("<tea> tea", 2000)],
        "coffee": [("<coffee> coffee", 2000)],
        "cigar": [("a <cigar> cigar", 3000), ("<cigar> cigars", 1000)],
        "term": [("<term>", 3000), ("the guest mentioned <term>", 2000), ("about <term>", 1000)]
    ]

    /// X-SAMPA pronunciations for words the stock model is unlikely to know, written with placeholder
    /// symbols where US and Singapore/British English differ (R, NG, OW). Words already in the model's
    /// vocabulary are ignored by the framework, so listing them is harmless.
    private static let pronunciations: [String: String] = [
        "Paiza": "p \"aI z @",
        "Waku": "w \"A k u",
        "Ghin": "g \"I n",
        "Wakuda": "w A \"k u d @",
        "Hibiki": "h I \"b i k i",
        "Yamazaki": "j A m @ \"z A k i",
        "Moët": "m OW \"E t",
        "Veuve": "v \"u v",
        "Clicquot": "k l i \"k OW",
        "Tieguanyin": "t i g w A n \"j I n",
        "Longjing": "l \"O NG dZ I NG",
        "Glenmorangie": "g l E n \"m O R @ n dZ i",
        "Glenlivet": "g l E n \"l I v @ t",
        "Glenfiddich": "g l E n \"f I d I k",
        "Ruinart": "R w i \"n A",
        "Cohiba": "k OW \"i b @",
        "Montecristo": "m Q n t i \"k R I s t OW",
        "Spago": "s p \"A g OW",
        "Sampan": "s \"{ m p { n",
        "Renku": "R \"E n k u",
        "Koma": "k \"OW m @",
        "Lavo": "l \"A v OW",
        "Macallan": "m @ \"k { l @ n",
        "Chivas": "S \"i v @ s",
        "Oolong": "\"u l Q NG",
        "Illy": "\"I l i",
        "Acqua": "\"A k w @",
        "Evian": "\"E v i Q n",
        "Pu'er": "p \"u E@"
    ]

    /// Builds training data for `terms`, keeping only templates, classes and pronunciations that apply.
    static func trainingData(locale: Locale, terms: [String], identifier: String, version: String) -> SFCustomLanguageModelData {
        let data = SFCustomLanguageModelData(locale: locale, identifier: identifier, version: version)

        // Each term on its own, lightly, so it exists even outside a template.
        for term in terms {
            data.insert(phraseCount: .init(phrase: term, count: 100))
        }

        // Group the user's terms into classes; unknown terms go to the generic class.
        var grouped: [String: [String]] = [:]
        for term in terms {
            let className = classes.first { $0.value.contains(term) }?.key ?? "term"
            grouped[className, default: []].append(term)
        }

        for (className, values) in grouped {
            guard let classTemplates = templates[className] else { continue }
            let generator = SFCustomLanguageModelData.TemplatePhraseCountGenerator()
            generator.define(className: className, values: values)
            for (template, count) in classTemplates {
                generator.insert(template: template, count: count)
            }
            data.insert(phraseCountGenerator: generator)
        }

        // Pronunciations for words that appear in the terms, translated to this locale's phoneme set.
        let supported = Set(SFCustomLanguageModelData.supportedPhonemes(locale: locale))
        let words = Set(terms.flatMap { $0.split(separator: " ").map(String.init) })
        for (grapheme, canonical) in pronunciations where words.contains(grapheme) {
            let phonemes = localized(canonical, for: locale)
            guard phonemes.allSatisfy(supported.contains) else { continue }
            data.insert(term: .init(grapheme: grapheme, phonemes: [phonemes.joined(separator: " ")]))
        }

        return data
    }

    /// Maps placeholder symbols to the locale's inventory: US English uses `r`, `ng`, `o`; British-style
    /// locales (en_SG, en_GB, …) use `r\`, `N`, `@U`. Stress marks (`"`, `%`) are kept.
    private static func localized(_ canonical: String, for locale: Locale) -> [String] {
        let isUS = locale.region?.identifier == "US" || locale.region?.identifier == "CA"
        let map: [String: String] = isUS
            ? ["R": "r", "NG": "ng", "OW": "o"]
            : ["R": "r\\", "NG": "N", "OW": "@U"]
        return canonical.split(separator: " ").map { token in
            var symbol = String(token)
            var stress = ""
            if let first = symbol.first, first == "\"" || first == "%" {
                stress = String(first)
                symbol.removeFirst()
            }
            return stress + (map[symbol] ?? symbol)
        }
    }
}
