import HouseScanKit

extension ScanViewState {
    /// How far the walk's aim task is toward done, 0...1, for the ring that fills (#81): the
    /// covered share of its band over the stretch the planner checks, `aimHalfWidth` either side
    /// of its s, over the share that completes it (`aimSatisfied`). The planner's numbers are
    /// read here, on the engine's side of the contract, so the screens don't import them.
    ///
    /// It reads the published strip, which holds the cells in view on the wall map
    /// (`CoverageMap.visibleRange`); the planner reads the whole map. Near an end of that range
    /// the two can differ by a cell. Nil for every step but an aim task.
    var aimProgress: Double? {
        let band: CoverageBand
        let s: Float
        switch guidance {
        case .aimAtGround(let at):
            band = .ground
            s = at
        case .aimAtWall(let at):
            band = .wall
            s = at
        default:
            return nil
        }
        let half = GuidancePlanner.aimHalfWidth
        let covered = coverage.coveredFraction(band, in: (s - half)...(s + half))
        return min(1, covered / GuidancePlanner.aimSatisfied)
    }
}
