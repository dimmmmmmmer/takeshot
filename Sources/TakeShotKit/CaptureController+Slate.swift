import CaptureCore
import Foundation

/// The creative metadata the operator sets BEFORE a take (the slate for the
/// next one) and corrects AFTER it (a wrong scene on the take that just
/// landed).
///
/// Split out of `+Naming`, which is about the FILE's name — prefix, cam, roll,
/// clip. Those describe where the recording lives; these describe what was
/// shot, and they follow different rules: the clip counter runs on for the
/// whole roll, a scene's takes restart at 1.
///
/// # Why a correction never touches the recorded file
///
/// Scene, shot and take are written into the .mov when the writer opens it
/// (`TakeWriter`), and NOTHING here ever rewrites them afterwards. That is a
/// decision, not a gap:
///
/// - There is no in-place metadata patch in AVFoundation. The two ways to
///   change a finalized movie's metadata are an `AVAssetExportSession`
///   passthrough, which writes a whole new file, and `AVMutableMovie` +
///   `writeHeader`, which appends a fresh moov atom to the existing one. The
///   first is not a correction, it is a re-delivery of camera original; the
///   second mutates a file the operator has already been told is safe, and any
///   bug in it costs the take rather than the note.
/// - The recording is evidence. TakeShot's own DIT offload writes ASC MHL
///   manifests over these files; changing a byte after a card has been copied
///   breaks the verification chain the DIT signed, and the mismatch surfaces
///   days later as "the footage was altered", which is the worst possible way
///   to learn about a typo in a scene number.
///
/// So a post-hoc edit updates the take list, the `takeshot-slate.csv` sidecar
/// and everything built from them — the log, the ALE, the reports, the remote.
/// The .mov keeps what it was slated with at the moment it was rolled, and the
/// sidecar is the newer of the two by construction. The restore in
/// `+LibraryRestore` reads it that way round on purpose.
extension CaptureController {
    /// Which half of the naming block the footer shows. Persisted like the
    /// operator's other choices; see `NamingPane` for why it is a switch.
    var namingPane: NamingPane {
        get { NamingPane(rawValue: settings.naming.namingPane ?? "") ?? .file }
        set {
            guard newValue != namingPane else { return }
            settings.naming.namingPane = newValue == .file ? nil : newValue.rawValue
        }
    }

    /// The slate the next take will be recorded with.
    var pendingSlate: SlateMetadata {
        SlateMetadata(scene: scene,
                      shot: SlateTakeField.number(from: shot),
                      take: slateTakeNumber)
    }

    /// The take number the next take gets inside its scene: the override when
    /// the operator has set one, else the clip counter, and 0 while no scene
    /// is being logged at all — an unslated day writes no take key.
    var slateTakeNumber: Int {
        if let slateTakeOverride { return slateTakeOverride }
        return isSlating ? nextTakeNumber : 0
    }

    /// Whether anything creative is being logged right now. The take number
    /// alone does not count: it always has a value to fall back on, so treating
    /// it as "slated" would stamp a take number on every file of a shoot that
    /// never opened the slate.
    var isSlating: Bool { !scene.isEmpty || !shot.isEmpty }

    /// What the footer's TAKE field shows. An unlogged take number is an EMPTY
    /// field, not a 0: blank is how the operator sees that numbering is still
    /// following the clip counter.
    var slateTakeFieldText: String {
        SlateTakeField.text(for: slateTakeNumber)
    }

    /// Apply the TAKE field: a number becomes an explicit override, a field
    /// naming none hands numbering back to the clip counter.
    ///
    /// What counts as a number is `SlateTakeField`, shared with the takes
    /// panel's copy of this field and with the phone — the three used to read
    /// the same typing three different ways, and all three write the same take
    /// number into the file's metadata and the sidecars.
    func commitSlateTakeText(_ text: String) {
        let number = SlateTakeField.number(from: text)
        slateTakeOverride = number > 0 ? number : nil
    }

    /// A new scene restarts its own take numbering; clearing the scene hands
    /// numbering back to the clip counter.
    ///
    /// Called from the `scene` observer — the controller's state file holds the
    /// property, not what it sets in motion, the same split `applyRollChange`
    /// keeps.
    func applySceneChange(from oldValue: String) {
        guard oldValue != scene else { return }
        slateTakeOverride = scene.isEmpty ? nil : 1
        pushConfig()
        refreshNameCollision()
    }

    /// The next take of the same scene, after one has landed. Only when the
    /// operator has actually taken numbering over: otherwise the clip counter
    /// is the number, and it advances on its own.
    func advanceSlateTake() {
        guard let slateTakeOverride else { return }
        self.slateTakeOverride = min(SlateTakeField.maximum, slateTakeOverride + 1)
    }

    // MARK: - correcting a take that has already been recorded

    /// Set the creative fields on a take already in the list. One entry point
    /// for the panel popover and for the web remote, so both produce the same
    /// sidecar rewrite (see the file comment for why the .mov is not touched).
    func setSlate(_ slate: SlateMetadata, description: String? = nil,
                  for take: Take) {
        guard let idx = takes.firstIndex(where: { $0.id == take.id }) else {
            return
        }
        let newDescription = description ?? takes[idx].logDescription
        guard takes[idx].slate != slate
            || takes[idx].logDescription != newDescription else { return }
        takes[idx].slate = slate
        takes[idx].logDescription = newDescription
        exportTakeLog()
    }
}
