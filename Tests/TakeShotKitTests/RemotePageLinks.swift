import Foundation

/// Every `href` a page's `<link>` elements carry.
///
/// The four page suites each asserted "no `<link>` at all", which was a proxy
/// for the rule that matters: these pages are opened on a set network that need
/// not have any internet behind it, so a page that FETCHES anything renders
/// wrong exactly when it matters. A `data:` href fetches nothing — the pages'
/// own tab icon is one — so the assertion had to become the intent, and four
/// copies of a parser is how four suites come to disagree about what a link is.
enum RemotePageLinks {
    static func hrefs(in html: String) -> [String] {
        var found: [String] = []
        var rest = Substring(html)
        while let open = rest.range(of: "<link ") {
            rest = rest[open.upperBound...]
            guard let close = rest.firstIndex(of: ">") else { break }
            let element = rest[..<close]
            if let href = element.range(of: "href=\"") {
                let value = element[href.upperBound...]
                if let end = value.firstIndex(of: "\"") {
                    found.append(String(value[..<end]))
                }
            } else {
                // A `<link>` with no href fetches nothing either, but it is not
                // something these pages write — reported as itself rather than
                // silently skipped.
                found.append("(no href)")
            }
            rest = rest[close...]
        }
        return found
    }
}
