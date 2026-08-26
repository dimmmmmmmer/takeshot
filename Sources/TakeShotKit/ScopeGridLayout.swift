import CoreGraphics

/// How many columns the scopes window puts its boxes in.
///
/// It used to be "as many 360pt columns as fit", which on a wide window laid
/// four scopes out in a single row of tall thin slivers — the arrangement the
/// owner asked to get away from: "отдельное окно скопов должно стремиться к
/// тому чтобы квадратную 2x2 сетку из скопов собирать".
///
/// So the rule is about the SHAPE of a box rather than how many will fit. Every
/// column count is tried, each is scored by how far one box's aspect ratio
/// lands from a comfortable one, and the best wins — which for four scopes is
/// 2×2 across almost every window a person would open, and for two is side by
/// side until the window is taller than it is wide.
enum ScopeGridLayout {
    /// Square. Three of the scopes are square by nature — the vectorscope, the
    /// histogram, and the CIE chart when it arrives — and the owner asked for a
    /// square grid outright. A wider target quietly defeats that: at 4:3 a
    /// 1600×900 window scores three columns above two, because 533×450 boxes
    /// are closer to 4:3 than 800×450 ones, and four scopes come out as a row
    /// of three with one underneath.
    static let preferredAspect: CGFloat = 1.0
    /// Under this a box stops being readable at all, whatever its shape.
    static let minimumBoxWidth: CGFloat = 260

    static func columns(for count: Int, in size: CGSize) -> Int {
        guard count > 1, size.width > 0, size.height > 0 else {
            return max(1, min(count, 1))
        }
        var best = 1
        var bestScore = CGFloat.greatestFiniteMagnitude
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let box = CGSize(width: size.width / CGFloat(columns),
                             height: size.height / CGFloat(rows))
            guard box.height > 0 else { continue }
            // Distance in RATIO rather than in points, so a box twice as wide
            // as it should be and one half as wide score the same.
            var score = abs(log(box.width / box.height / preferredAspect))
            // A grid that cannot be filled leaves holes in the last row, and
            // the cost is per hole rather than per raggedness: five scopes in
            // four columns leaves three, five in three leaves one, and the
            // second is the layout a person would draw.
            let holes = columns * rows - count
            score += 0.25 * CGFloat(holes)
            // Too narrow to read is worse than any shape.
            if box.width < minimumBoxWidth { score += 10 }
            if score < bestScore { bestScore = score; best = columns }
        }
        return best
    }
}
