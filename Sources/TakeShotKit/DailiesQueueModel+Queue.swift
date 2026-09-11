import CaptureCore
import Foundation

/// **What a dailies run is made of, and what the sheet says about it.**
///
/// Split out of `DailiesQueueModel` when that type reached its length ceiling.
/// It is a coherent piece rather than an arbitrary cut: everything here answers
/// one question — files or takes — for the three readers that ask it (what
/// Start queues, what the preview describes, and which frame it lays its strips
/// over), and the whole point is that they get ONE answer.
extension DailiesQueueModel {
    /// **What a run is made of**: the files the folders hold, or the app's own
    /// takes. One or the other and never both — see `queuedTakes`.
    ///
    /// Stated once because three things ask it now — what Start queues, what
    /// the preview draws, and which frame that preview lays its strips over —
    /// and a fourth reader spelling `sources.isEmpty` again is how a preview
    /// comes to show a take while the run renders a card.
    enum QueueContents {
        case files([URL])
        case takes([Take])

        /// The first file a run would touch — what the preview's frame is
        /// decoded from.
        var firstURL: URL? {
            switch self {
            case .files(let urls): return urls.first
            case .takes(let takes): return takes.first?.url
            }
        }
    }

    var queueContents: QueueContents {
        Self.contents(sources: sources, findings: findings, takes: queuedTakes,
                      goodOnly: goodTakesOnly)
    }

    /// **The takes a run would actually render**: all of them, or the circled
    /// ones alone.
    ///
    /// One place, because four things ask what the queue holds — the button's
    /// count, the preview's frame, the strips over it and Start itself — and a
    /// filter applied at three of them is how a sheet comes to promise a
    /// different run from the one it makes.
    ///
    /// A run from SOURCE FOLDERS is unaffected by construction: a clip on a
    /// card has no rating to be circled, the ratings are this app's own takes'
    /// (see `CaptureController.canFilterDailiesToGoodTakes`, which greys the
    /// switch rather than letting it lie).
    var takesToRender: [Take] {
        goodTakesOnly ? queuedTakes.filter { $0.rating == .good } : queuedTakes
    }

    /// The rule over VALUES, so a subscriber can ask it about the values it was
    /// just handed.
    ///
    /// `@Published` fires in `willSet` — before the new value is on the object
    /// — so a subscriber that reads `self` reads the state the change is
    /// replacing. That is documented one screen up for the settings write and
    /// it is the same trap here: asked about `self`, the preview compared the
    /// PREVIOUS card's first clip with itself, found no change, and never
    /// refreshed.
    static func contents(sources: [URL],
                         findings: DailiesSourceScan.Findings,
                         takes: [Take],
                         goodOnly: Bool = false) -> QueueContents {
        guard sources.isEmpty else { return .files(findings.files) }
        return .takes(goodOnly ? takes.filter { $0.rating == .good } : takes)
    }

    /// The queue Start will run.
    func plannedItems(settings: CaptureSettings) -> [DailiesItem] {
        switch queueContents {
        case .files(let urls):
            return urls.map {
                Self.item(for: $0, settings: settings,
                          prefix: namePrefix, suffix: nameSuffix)
            }
        case .takes(let takes):
            return takes.map {
                Self.item(for: $0, settings: settings,
                          prefix: namePrefix, suffix: nameSuffix)
            }
        }
    }

    /// What the burn-in preview describes: the first item the run would
    /// produce, or nil when nothing is queued and the preview falls back to
    /// its sample.
    ///
    /// On the model rather than in the view, and that is not tidiness: the
    /// preview's texts are read from a computed property, and a computed
    /// property that reaches for an `@EnvironmentObject` traps when a render
    /// test asks for it directly — which has already taken a whole battery
    /// down once (`DailiesBurninPreview.still`).
    var previewItem: DailiesItem? {
        guard let settings = controller?.settings else { return nil }
        return firstPlannedItem(settings: settings)
    }

    /// The first item that run would produce, or nil when nothing is queued —
    /// what the burn-in preview describes.
    ///
    /// Not `plannedItems(settings:).first`: a shuttle drive holds a thousand
    /// clips and this is asked on every render of the sheet.
    func firstPlannedItem(settings: CaptureSettings) -> DailiesItem? {
        switch queueContents {
        case .files(let urls):
            return urls.first.map {
                Self.item(for: $0, settings: settings,
                          prefix: namePrefix, suffix: nameSuffix)
            }
        case .takes(let takes):
            return takes.first.map {
                Self.item(for: $0, settings: settings,
                          prefix: namePrefix, suffix: nameSuffix)
            }
        }
    }

    // MARK: - what the burn-ins are, as a value

    var burnins: DailiesBurnins {
        DailiesBurnins(
            timecode: burnTimecode, clipName: burnClipName,
            project: burnProject, date: burnDate,
            // The switch decides, and the words are left alone: the engine's
            // rule is still "empty text, no strip", so switching the line off
            // is expressed by handing it nothing while the operator's sentence
            // stays in the field and in settings.
            customText: burnCustom
                ? customText.trimmingCharacters(in: .whitespaces) : "",
            timecodePosition: timecodePosition,
            clipNamePosition: clipNamePosition,
            projectPosition: projectPosition,
            customPosition: customPosition,
            datePosition: datePosition,
            ink: ink, customInk: customInk)
    }
}
