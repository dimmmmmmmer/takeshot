import Foundation
import JavaScriptCore
import Testing

@testable import TakeShotKit

/// The five pages the server hands to a phone, checked as SOURCE.
///
/// Everything else about the remote is tested through the server: a request
/// goes in, bytes come back, and a substring is asserted. That cannot see the
/// two ways a page fails as a program rather than as a response — and both
/// reach the operator as a page that simply does not work, with a 200 in the
/// log and nothing anywhere to say why.
///
/// 71 kB of JavaScript ships inside these files. No compiler reads it, no
/// linter reads it, and the only reader before now was a person opening the
/// page on a handset.
@MainActor
struct RemotePageSourceTests {
    /// The pages as the server actually holds them, by the same calls
    /// `startRemoteServer` makes.
    static func pages() throws -> [(name: String, html: String)] {
        try [("remote", RemotePage.html()),
             ("script", RemotePage.scriptHTML()),
             ("cameras", RemotePage.camerasHTML()),
             ("live", RemotePage.liveHTML()),
             ("slate", RemotePage.slateHTML())]
            .map { page in
                (page.0, try #require(String(bytes: page.1, encoding: .utf8),
                                      "the \(page.0) page is not UTF-8"))
            }
    }

    /// The body of every `<script>` element in `html`, in document order.
    static func scriptBodies(in html: String) -> [String] {
        var bodies: [String] = []
        var rest: Substring = html[...]
        while let open = rest.range(of: "<script"),
              let headEnd = rest[open.upperBound...].firstIndex(of: ">") {
            let bodyStart = rest.index(after: headEnd)
            guard let close = rest[bodyStart...].range(of: "</script>") else { break }
            bodies.append(String(rest[bodyStart..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return bodies
    }

    /// Every served page's JavaScript parses — in BOTH languages, because the
    /// language is baked into the bytes.
    ///
    /// `RemotePage.render` splices a config object into the script, and the
    /// `strings:` half of it is `L()` output. So the served program is a
    /// different program per language, and a label that broke the parse would
    /// break it for Russian operators alone — the half of the audience the
    /// developer never renders.
    ///
    /// Parsed rather than run: `new Function(source)` compiles the text and
    /// stops, so nothing here touches `document`, `WebSocket` or
    /// `RTCPeerConnection`, none of which exist in a `JSContext`. What that
    /// cannot catch is anything a parser is entitled to accept — a typo'd
    /// identifier is a runtime `ReferenceError` and passes this cleanly. It
    /// catches the class that makes the WHOLE file dead: an unbalanced brace,
    /// an unterminated string or template, a stray character from an edit.
    ///
    /// JavaScriptCore rather than node: it is a system framework, so this needs
    /// nothing installed on the runner and cannot go quiet if a toolchain moves.
    @Test func everyServedPagesJavaScriptParsesInBothLanguages() throws {
        for language in [AppLanguage.english, .russian] {
            let pages: [(name: String, html: String)] =
                try ViewRender.withLanguage(language) { try Self.pages() }
            var characters: Int = 0
            for page in pages {
                let bodies: [String] = Self.scriptBodies(in: page.html)
                #expect(!bodies.isEmpty,
                        "\(page.name) [\(language)] served no script at all")
                for (index, body) in bodies.enumerated() {
                    characters += body.count
                    let context = try #require(JSContext(),
                                               "no JavaScript context")
                    context.setObject(body as NSString,
                                      forKeyedSubscript: "source" as NSString)
                    // The parse itself. A SyntaxError lands in `exception`.
                    _ = context.evaluateScript("new Function(source)")
                    let failure: String? = context.exception?.toString()
                    #expect(failure == nil,
                            """
                            \(page.name) [\(language)] script \(index + 1) does \
                            not parse, so the whole page is dead on a phone: \
                            \(failure ?? "")
                            """)
                }
            }
            // A floor under "the extractor found the scripts at all", so a
            // broken reader cannot come back green having parsed "".
            #expect(characters > 50_000,
                    "only \(characters) characters of JavaScript found in \(language)")
        }
    }

    /// A quoted value can never close the script element it is spliced into,
    /// and survives being read back.
    ///
    /// Found by mutation rather than by reading: putting `</script>` into one
    /// Russian label broke the live page for Russian alone — one script became
    /// two, neither of which parsed — while English stayed green. The JSON was
    /// never wrong; an HTML parser looks for `</script` in a script element's
    /// text before any JavaScript parser sees a string, so correct escaping of
    /// quotes and backslashes does nothing about it.
    ///
    /// Today's only inputs to the config are the two `.strings` files, so this
    /// is depth rather than a live hole — but `quoted` is also what writes the
    /// status a phone receives, whose values are a take's comment, a roll name
    /// and a file name, all typed by somebody. One of those reaching a script
    /// element later is a change nobody would think to re-audit this for.
    ///
    /// The second half matters as much as the first: an escape that made the
    /// page safe by CHANGING the operator's text would be a different bug, so
    /// every case is parsed back with JSON.parse and compared to the original.
    @Test func aQuotedValueCannotCloseTheScriptItSitsIn() throws {
        let hostile: [String] = [
            "</script>", "</SCRIPT >", "<!-- x -->", "a < b && c > d",
            "\"quotes\" and \\backslashes\\", "line\nbreak\ttab",
            "Дубль 12А — «крупный»", "emoji 🎬 and a \u{7} bell",
            "", "%@ %d 100%",
        ]
        let context = try #require(JSContext(), "no JavaScript context")
        for value in hostile {
            let json: String = RemoteJSON.quoted(value)
            #expect(!json.contains("<"),
                    "quoted(\(value)) still carries a bare < : \(json)")

            // …and it is still the same string on the other side.
            context.setObject(json as NSString,
                              forKeyedSubscript: "json" as NSString)
            let parsed = context.evaluateScript("JSON.parse(json)")
            #expect(context.exception == nil,
                    """
                    quoted(\(value)) is not parseable JSON: \
                    \(context.exception?.toString() ?? "")
                    """)
            context.exception = nil
            let back: String = parsed?.toString() ?? "nil"
            #expect(back == value,
                    "quoting changed the text: \(value) came back as \(back)")
        }
    }

    /// Every served page lets the four digits be TYPED.
    ///
    /// The PIN never travels in a URL — the QR encodes the address alone, on
    /// purpose, because the code on the cart is read out to the people meant to
    /// have it. So the gate's field is the only way into a handset that has not
    /// opened the page before, and it has to work on all of them.
    ///
    /// The CSS half of that is not decoration. Every page sets
    /// `user-select: none` on `html, body` so a finger resting on the timecode
    /// does not start a selection; `user-select` INHERITS, and WebKit will not
    /// put a caret in a field that computes to `none`. The operator page — the
    /// one with REC on it — was the only one whose `#pin` rule did not turn it
    /// back on, so the tap did nothing and no keyboard came up. Nothing about
    /// that is visible in the markup: the field, the button and the handler
    /// were all present and correct.
    @Test func everyServedPageLetsThePINBeTyped() throws {
        for page in try Self.pages() {
            let rule = try #require(Self.cssRule("#pin", in: page.html),
                                    "\(page.name) has no #pin rule at all")
            #expect(rule.contains("user-select: text"),
                    """
                    the \(page.name) page's PIN field inherits \
                    user-select: none, so WebKit will not place a caret in it \
                    and the code cannot be typed
                    """)
        }
    }

    /// The declaration block of one CSS rule, or nil when the page has no such
    /// selector. Enough of a parser for the stylesheets this repository writes:
    /// each page carries one `<style>`, and no rule nested inside an at-rule
    /// names `#pin`.
    static func cssRule(_ selector: String, in html: String) -> String? {
        guard let start = html.range(of: selector + " {"),
              let end = html[start.upperBound...].firstIndex(of: "}")
        else { return nil }
        return String(html[start.upperBound..<end])
    }

    /// Nothing on a served page builds DOM out of a string.
    ///
    /// Every dynamic value on these pages — a take's comment, a camera's name,
    /// a file name, a slate — is text somebody TYPED, arriving over the socket
    /// and going into the document. All five pages put it there with
    /// `textContent`, which cannot make markup out of it, and none of them uses
    /// `innerHTML`, `outerHTML`, `insertAdjacentHTML` or `document.write`.
    ///
    /// That is a property held by discipline alone: one `innerHTML =` in a
    /// later edit would turn a roll name into markup, on a page that is
    /// PIN-gated rather than private — a set network with a four-digit code is
    /// not a trust boundary, which is the same reasoning `RemoteTextBoundTests`
    /// already applies to what an authenticated socket may spend.
    ///
    /// Matched on the property ACCESS — the dot is part of the pattern — rather
    /// than on the bare word, so a comment saying "we never use innerHTML"
    /// does not fail this. Prose that spells out a whole assignment
    /// (`el.innerHTML = x`) still does, which is the side to err on.
    ///
    /// The dot is there because the first version of this test did not have it
    /// and was wrong: whitespace is squeezed out before matching, which turned
    /// the comment "never innerHTML = anything here" into `neverinnerHTML=`
    /// and failed it. The inverse mutation — the word in a comment, which must
    /// stay GREEN — is what found that, and it is the reason this suite runs
    /// one.
    @Test func noServedPageBuildsDOMFromAString() throws {
        let forbidden: [(pattern: String, why: String)] = [
            (".innerHTML=", "assigns innerHTML"),
            ("[\"innerHTML\"]=", "assigns innerHTML"),
            (".outerHTML=", "assigns outerHTML"),
            ("[\"outerHTML\"]=", "assigns outerHTML"),
            (".insertAdjacentHTML(", "calls insertAdjacentHTML"),
            ("document.write(", "calls document.write"),
            ("document.writeln(", "calls document.writeln"),
        ]
        var scripts: Int = 0
        for page in try Self.pages() {
            for body in Self.scriptBodies(in: page.html) {
                scripts += 1
                // Whitespace around `=` and inside a call is not the question;
                // squeezing it out means one pattern per API rather than four.
                let squeezed = String(body.filter { !$0.isWhitespace })
                for rule in forbidden {
                    #expect(!squeezed.contains(rule.pattern),
                            """
                            the \(page.name) page \(rule.why) — a value an \
                            operator typed becomes markup on somebody's phone. \
                            Every other value on these pages goes in through \
                            textContent.
                            """)
                }
            }
        }
        #expect(scripts >= 5, "only \(scripts) scripts read; the walk found nothing")
    }
}
