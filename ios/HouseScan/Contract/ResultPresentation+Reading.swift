import HouseScanKit

// What the result screen leads with, read from the presentation by HouseScanKit's
// `ResultReading`, where the rules are tested. Reading the presentation rather than the server's
// answer means the engine's results and the UI demo's samples go through the same rules.

extension ResultPresentation {
    /// True when there is a spot and the meter working-space check at it, if the server ran one,
    /// passed.
    var spotIsClean: Bool {
        ResultReading.spotIsClean(hasSpot: spot != nil, checks: readingChecks)
    }

    var answer: ResultReading.Answer {
        ResultReading.answer(decision: placementDecision, policyApproved: policyApproved, hasSpot: spot != nil, checks: readingChecks,
                             unmeasuredMarks: !unmeasuredMarks.isEmpty)
    }

    /// The check lines on the result card, in the order `ResultReading.cardLines` gives.
    var cardChecks: [CheckRow] {
        ResultReading.cardLines(readingChecks).map { checks[$0] }
    }

    /// The view that would settle `row` and that the camera can take now: only for an unsure
    /// check a person needn't judge.
    func viewToTake(for row: CheckRow) -> MissingEvidence? {
        guard row.outcome == .unsure, !row.needsPerson, let id = row.settledBy else { return nil }
        return missing.first { $0.id == id && $0.capturable }
    }

    /// The first view in `missing` that settles an unsure check and can be taken now.
    var firstViewToTake: MissingEvidence? {
        let wanted = Set(checks.compactMap { viewToTake(for: $0)?.id })
        return missing.first { wanted.contains($0.id) }
    }

    private var readingChecks: [ResultReading.Check] {
        checks.map { row in
            ResultReading.Check(
                id: row.id, outcome: row.outcome.placementOutcome, needsPerson: row.needsPerson,
                viewCapturable: viewToTake(for: row) != nil,
                margin: ResultReading.margin(
                    measured: row.measured.map(Double.init), threshold: row.threshold.map(Double.init),
                    plusMinus: row.plusMinus.map(Double.init), comparison: row.comparison?.placementComparison)
            )
        }
    }

    private var placementDecision: PlacementDecision {
        switch decision {
        case .pass: .pass
        case .manualReview: .manualReview
        case .reject: .reject
        }
    }
}

private extension CheckOutcome {
    var placementOutcome: PlacementOutcome {
        switch self {
        case .pass: .pass
        case .fail: .fail
        case .unsure: .unsure
        }
    }
}

private extension RuleComparison {
    var placementComparison: PlacementComparison {
        switch self {
        case .atLeast: .atLeast
        case .atMost: .atMost
        }
    }
}
