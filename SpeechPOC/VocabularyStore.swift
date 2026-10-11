import Foundation
import Observation

/// Custom vocabulary shared by both transcription tabs, so Local and Whisper are biased towards the
/// same terms and can be compared fairly.
@MainActor
@Observable
final class VocabularyStore {

    /// Program terms plus the MBS seed list from cloud/whisper-server/vocab.py.
    var terms: [String] = [
        "Paiza Chairman", "Paiza Diamond", "Sands Lifestyle", "SRC", "Sands Rewards Club", "GRA",
        "Marina Bay Sands", "MBS", "Paiza", "Sands", "SkyPark",
        "ArtScience", "Shoppes", "Marquee", "Avenue", "Sampan", "Renku",
        "Chairman Suite", "Premier Suite", "Orchid Suite",
        "Presidential Suite", "Club", "Deluxe",
        "Spago", "Cut", "Waku Ghin", "Wakuda", "Punjab Grill", "db Bistro",
        "Bread Street Kitchen", "Lavo", "Koma", "Origin Bar", "Yardbird",
        "Mott 32", "Adrift", "RISE", "CÉ LA VI",
        "Yamazaki", "Hibiki", "Macallan", "Glenfiddich", "Glenmorangie", "Glenlivet",
        "Hennessy", "Rémy Martin", "Don Julio", "Patrón",
        "Johnnie Walker", "Chivas", "Bowmore",
        "Perrier", "Evian", "San Pellegrino", "Voss", "Fiji", "Acqua Panna",
        "Dom Pérignon", "Krug", "Veuve Clicquot", "Moët", "Bollinger", "Ruinart",
        "Longjing", "Tieguanyin", "Oolong", "Pu'er", "Earl Grey",
        "TWG", "Illy", "Nespresso",
        "Cohiba", "Davidoff", "Montecristo"
    ]

    /// Trimmed, non-empty terms ready to hand to a recognizer.
    var cleanedTerms: [String] {
        terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !terms.contains(trimmed) else { return }
        terms.append(trimmed)
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
    }
}
