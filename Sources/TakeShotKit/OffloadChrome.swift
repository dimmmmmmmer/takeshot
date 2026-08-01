import SwiftUI

/// The one type family the offload and verify sheets are set in.
///
/// It used to be five sizes and four weights across two sheets: `.headline`,
/// `.subheadline.weight(.semibold)`, the default body, `.callout`, `.caption`,
/// `.caption.weight(.semibold)` and a bare `.fontWeight(.semibold)`, chosen a
/// line at a time. Side by side in one card that reads as a ransom note, and
/// nothing in it says which of two lines matters more — everything is shouting
/// slightly differently.
///
/// Three sizes and two weights, and every `Text` in the offload and verify
/// sheets goes through `offloadText(_:)`, so a label added later cannot drift
/// off the family by accident. Same idea as `PlayerChrome` and its
/// `playerChromePlate()`, and for the same reason: the constants and the one
/// modifier are the family, not a convention somebody has to remember.
enum OffloadChrome {
    /// Between the sheet's own blocks (source, destinations, progress…).
    static let sectionSpacing: CGFloat = 14
    /// Between rows inside a block.
    static let rowSpacing: CGFloat = 8
    /// Between a line and the line that explains it.
    static let tightSpacing: CGFloat = 4
    /// A result/history card's own inset and corner.
    static let cardPadding: CGFloat = 10
    static let cardRadius: CGFloat = 8
    /// How much of the card's colour is left in its plate. Enough to read as a
    /// verdict, not enough to fight the text on it.
    static let cardTintOpacity: Double = 0.08
}

/// What a line of text IS, rather than what size it should be. The size follows
/// from the role, which is the point — a caller picking `.caption` because the
/// line "feels small" is how the zoo grew the first time.
enum OffloadTextRole {
    /// The sheet's own heading. One per sheet.
    case title
    /// A block heading, or the name of the destination a card is about.
    case section
    /// Sentences and values the operator reads.
    case body
    /// Secondary detail: rates, counts, hints, file lists.
    case caption

    var font: Font {
        switch self {
        case .title: return .headline
        case .section: return .callout.weight(.semibold)
        case .body: return .callout
        case .caption: return .caption
        }
    }

    /// Captions are the quiet half of the family; everything else is primary
    /// unless the caller states a verdict colour.
    var defaultStyle: AnyShapeStyle {
        switch self {
        case .caption: return AnyShapeStyle(HierarchicalShapeStyle.secondary)
        default: return AnyShapeStyle(HierarchicalShapeStyle.primary)
        }
    }
}

extension View {
    /// Set this text in the offload family (see `OffloadChrome`).
    ///
    /// `tint` is the one thing a caller may override, and only ever to state a
    /// verdict — green/orange/red carry meaning here. Size and weight are not
    /// parameters: those are the family.
    func offloadText(_ role: OffloadTextRole, tint: Color? = nil) -> some View {
        font(role.font)
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? role.defaultStyle)
    }
}
