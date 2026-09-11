import CoreGraphics

/// **How tall a histogram bin is drawn** — one function, because it is the
/// whole shape of the instrument.
///
/// **It was logarithmic, and that is why ours did not look like anyone
/// else's** (owner, with a Resolve histogram beside ours: "мне кажется у нас
/// гистограмма не оч верная"). The argument for the log was that a linear
/// scale turns a frame with one dominant tone into a lone spike over a flat
/// line — true, and the cure was worse: `log(count + 1) / log(peak + 1)` puts
/// a bin holding a TENTH of the peak at 88 % of full height and a hundredth at
/// 76 %, so every ordinary picture came out as a plateau with its shape
/// squeezed into the top eighth of the row. An operator reads a histogram for
/// where the weight of the picture IS, and ours was answering "everywhere".
///
/// Linear, normalised to the tallest bin, which is what Resolve, Baselight,
/// Nuke and every camera's own histogram do. The spike case is real and is
/// also the instrument being right: a frame that is nine tenths one tone IS a
/// spike, and a scale that hides that is a scale that lies about the picture.
enum ScopeHistogramScale {
    /// Bin height in points. `peak` is the tallest bin in the same series —
    /// per channel, so a red-dominant frame does not flatten the blue row.
    static func height(count: Int, peak: Int, rowHeight: CGFloat) -> CGFloat {
        guard count > 0, peak > 0, rowHeight > 0 else { return 0 }
        return rowHeight * CGFloat(min(1, Double(count) / Double(peak)))
    }
}
