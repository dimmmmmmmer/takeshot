import AppKit
import Foundation
import UniformTypeIdentifiers

/// "Ask the operator for a path", in one place.
///
/// Every file dialog the app opens goes through here: the four export documents
/// (`+Reports`), the record-folder picker, the look importer, the chroma plate
/// picker, and the offload sheet's source/destination browsers.
///
/// **Why a seam and not just a call.** `NSSavePanel.runModal()` stops the
/// calling thread until somebody clicks a button, so a test that reaches an
/// exporter hangs the whole suite — which is why the four documents in
/// `+Reports` had no coverage at all. What is worth asserting about an export is
/// everything on the other side of the panel: which file name is offered, which
/// folder it is offered in, what the bytes turn out to be, and what the operator
/// is told when the write fails. So the suite replaces `saveHandler` with one
/// that records the request and answers with a scratch URL — or with nil, which
/// is how "the operator pressed Cancel" is spelled.
///
/// Same shape as `FinderOpen` beside it, for the same reasons: main-actor state,
/// and the suite is serial, so a substitution cannot leak sideways into another
/// test.
@MainActor
enum FilePanel {
    /// What a save panel is asked to offer. The suite reads both fields: a
    /// document offered under the wrong name, or in a folder that is not the
    /// day's, is a real failure and an invisible one.
    struct SaveRequest: Equatable {
        var suggestedName: String
        var directory: URL?
    }

    /// What an open panel is asked to offer. Defaults are `NSOpenPanel`'s own —
    /// files yes, folders no — so a caller states only what it changes.
    struct OpenRequest: Equatable {
        var files = true
        var directories = false
        var createDirectories = false
        var multiple = false
        var contentTypes: [UTType] = []
        var directory: URL?
        var message: String?
        var prompt: String?
    }

    /// What actually runs the panels. Replaced by the suite; never by the app.
    ///
    /// Only `runModal()` and reading the result are in here — building the panel
    /// is `configured(…)` below, so which switches a request turns on can be
    /// asserted against the real `NSOpenPanel` rather than only against the
    /// request that asked for them.
    static var saveHandler: (SaveRequest) -> URL? = { request in
        let panel = configured(request)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
    static var openHandler: (OpenRequest) -> [URL] = { request in
        let panel = configured(request)
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    /// Where to write a document. nil — the operator cancelled.
    static func save(named name: String, in directory: URL?) -> URL? {
        saveHandler(SaveRequest(suggestedName: name, directory: directory))
    }

    /// What the operator chose. Empty — they cancelled.
    static func open(_ request: OpenRequest) -> [URL] {
        openHandler(request)
    }

    /// The one thing the operator chose, for the pickers that take exactly one.
    static func openOne(_ request: OpenRequest) -> URL? {
        openHandler(request).first
    }

    // MARK: - the real panels

    /// A save panel set up for `request`, not yet shown. Separate from the
    /// handler so the setup can be checked without a human in front of it:
    /// building an `NSSavePanel` costs nothing and shows nothing — it is
    /// `runModal()` that stops the thread.
    static func configured(_ request: SaveRequest) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = request.suggestedName
        panel.directoryURL = request.directory
        return panel
    }

    /// An open panel set up for `request`, not yet shown. Which switches a
    /// caller turns on is the whole content of a browse dialog — a folder picker
    /// that also accepts files sends the operator picking a movie as a record
    /// destination — so the mapping is worth holding against the real object.
    static func configured(_ request: OpenRequest) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = request.files
        panel.canChooseDirectories = request.directories
        panel.canCreateDirectories = request.createDirectories
        panel.allowsMultipleSelection = request.multiple
        // Assigning an empty list would filter everything out; a picker that
        // names no types wants them all.
        if !request.contentTypes.isEmpty {
            panel.allowedContentTypes = request.contentTypes
        }
        if let directory = request.directory { panel.directoryURL = directory }
        if let message = request.message { panel.message = message }
        if let prompt = request.prompt { panel.prompt = prompt }
        return panel
    }
}
