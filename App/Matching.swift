import Foundation

/// The two cards can name the same subject differently — "&" against "and", a
/// truncated title, a trailing "Lab" — so tie them together by normalising and
/// then trying progressively looser tests.
///
/// Returning nil is a valid answer: better to show no attendance than another
/// subject's.

private let stopWords: Set<String> = [
    "and", "the", "of", "for", "to", "in", "a", "an", "lab", "theory",
]

private func normalise(_ s: String) -> String {
    let expanded = s.lowercased().replacingOccurrences(of: "&", with: " and ")
    let kept = expanded.map { c -> Character in
        (c.isLetter && c.isASCII) || c.isNumber ? c : " "
    }
    return String(kept)
        .split(separator: " ", omittingEmptySubsequences: true)
        .joined(separator: " ")
}

private func tokenSet(_ s: String) -> Set<String> {
    Set(
        normalise(s)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    )
}

func matchSubject(_ name: String, in rows: [AttRow]) -> AttRow? {
    guard !name.isEmpty, !rows.isEmpty else { return nil }
    let n = normalise(name)

    if let hit = rows.first(where: { normalise($0.key) == n }) { return hit }

    // Several rows can be prefix-compatible at once: "Engineering Physics" and
    // "Engineering Physics Lab" both prefix "Engineering Physics Laboratory".
    // Taking the first in document order picked by accident, so prefer the key
    // closest in length to the query, and give up on a tie rather than tossing
    // a coin between two subjects.
    if n.count > 6 {
        let prefixHits =
            rows
            .map { ($0, normalise($0.key)) }
            .filter { $0.1.count > 6 && ($0.1.hasPrefix(n) || n.hasPrefix($0.1)) }
            .sorted { abs($0.1.count - n.count) < abs($1.1.count - n.count) }

        if prefixHits.count == 1 { return prefixHits[0].0 }
        if prefixHits.count > 1 {
            let best = abs(prefixHits[0].1.count - n.count)
            let tied = abs(prefixHits[1].1.count - n.count) == best
            return tied ? nil : prefixHits[0].0
        }
    }

    let a = tokenSet(name)
    guard !a.isEmpty else { return nil }

    var best: AttRow?
    var bestScore = 0.0
    for r in rows {
        let b = tokenSet(r.key)
        if b.isEmpty { continue }
        let shared = a.intersection(b).count
        let score = Double(shared) / Double(min(a.count, b.count))
        if score > bestScore {
            bestScore = score
            best = r
        }
    }
    // Below this the guesses stop being useful and start being wrong.
    return bestScore >= 0.6 ? best : nil
}
