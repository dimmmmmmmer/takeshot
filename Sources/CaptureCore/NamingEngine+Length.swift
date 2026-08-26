import Foundation

/// How long a composed take name is allowed to be, and what it gives up when it
/// is longer.
///
/// The engine had no length rule at all. Nothing in the naming fields refuses a
/// long value and nothing downstream shortens one, so a pasted project prefix
/// plus scene, shot, take, camera and roll composed a name the file system
/// simply refuses — **measured on this Mac (APFS): `open(2)` returns
/// `ENAMETOOLONG` (errno 63) and `AVAssetWriter.startWriting()` returns false
/// with `NSURLErrorCannotCreateFile` / OSStatus -12143.** So it is not a
/// truncation and not a finalize failure: the take never opens, and the
/// operator finds out when the camera is already rolling.
extension NamingEngine {
    /// The longest a single path component may be, in UTF-8 bytes.
    ///
    /// 255 is the number every file system a DIT writes to agrees on as a
    /// maximum, and the unit they disagree about. It is BYTES on SMB, NFS and a
    /// Linux-formatted card, which is the tighter reading and therefore the one
    /// to build on: a name that fits here fits everywhere the footage might be
    /// written or copied to.
    static let maximumPathComponentBytes = 255

    /// …and the same 255 in the unit macOS itself counts, which is not bytes.
    ///
    /// Measured, because the documentation and the folklore both say "bytes"
    /// and neither is right: 255 Cyrillic `Ы` (510 UTF-8 bytes) and 255 CJK
    /// `漢` (765 bytes) are both accepted, while 127 `й` — two bytes composed —
    /// is the maximum, because macOS decomposes before counting and each one
    /// becomes two units. So the enforced limit is 255 UTF-16 code units of the
    /// DECOMPOSED form, and neither budget implies the other: a name can pass
    /// the byte count and fail this (a run of characters that decompose into
    /// three units apiece), or pass this and fail the byte count on a share.
    /// Both are checked.
    ///
    /// Canonical NFD rather than the HFS+ variant macOS actually uses, which
    /// leaves some ranges composed — so this over-counts slightly and never
    /// under-counts, which is the direction to be wrong in.
    static let maximumPathComponentUnits = 255

    /// Reserved out of both budgets for what the take path still appends after
    /// the name is composed, all of it ASCII:
    ///
    /// - `.mov` (4) — `takeFileURL` adds the extension;
    /// - `_FAILED` (7) — a take whose finalize failed is renamed rather than
    ///   re-adopted by the folder scan, and that rename failing would put a
    ///   broken take back in the library (`CapturePipeline.markFailed`);
    /// - `_999` (4) — the collision suffix `uniqueURL` adds.
    ///
    /// This headroom is what makes the uniqueness guarantee below real rather
    /// than probabilistic: even if two shortened names came out identical,
    /// `uniqueURL` still has room to make the second one different, and its
    /// suffixed name still fits.
    static let reservedTakePathLength = 15

    /// What `fileName(for:)` returns at most, in UTF-8 bytes.
    static let fileNameByteBudget =
        maximumPathComponentBytes - reservedTakePathLength

    /// …and in decomposed UTF-16 units.
    static let fileNameUnitBudget =
        maximumPathComponentUnits - reservedTakePathLength

    /// What macOS counts a path component's length in.
    static func pathUnits(_ value: String) -> Int {
        value.decomposedStringWithCanonicalMapping.utf16.count
    }

    /// Whether a name is over either budget.
    static func exceedsBudget(_ name: String, bytes byteLimit: Int,
                              units unitLimit: Int) -> Bool {
        name.utf8.count > byteLimit || pathUnits(name) > unitLimit
    }

    /// A composed name cut to the budget, keeping the parts that identify the
    /// take.
    ///
    /// **The prefix gives its tail back first, and the clip number never does.**
    /// Two takes whose names collided after truncation is a far worse failure
    /// than a shortened project name: the operator would be looking for the
    /// second take under a name the first one already has. So the shortening
    /// happens BEFORE substitution, on `context.project` alone, and the
    /// template's own structure — camera, roll, clip, postfix, timecode — is
    /// composed from the untouched values around it.
    ///
    /// A marker of the full name's xxHash64 is appended. It says the name was
    /// shortened rather than typed that way, and it is what keeps two prefixes
    /// that differ only past the cut apart. Where it cannot alone —
    /// astronomically unlikely, but a hash is not a promise — `uniqueURL` still
    /// has the four bytes `reservedTakePathLength` set aside for it, so the
    /// second take gets its own file either way and never overwrites the first.
    func shortened(_ composed: String, for context: NamingContext) -> String {
        let marker = Self.truncationMarker(for: composed)
        let byteBudget = Self.fileNameByteBudget - marker.utf8.count
        let unitBudget = Self.fileNameUnitBudget - marker.utf16.count

        var trimmed = context
        trimmed.project = Self.truncated(context.project, toBytes: byteBudget,
                                         units: unitBudget)
        var candidate = compose(trimmed)
        while Self.exceedsBudget(candidate, bytes: byteBudget, units: unitBudget),
              !trimmed.project.isEmpty {
            // give back the byte overflow in one step where there is one, and a
            // character at a time when it is the unit budget that binds
            trimmed.project = Self.droppingLast(
                trimmed.project,
                atLeastBytes: candidate.utf8.count - byteBudget)
            candidate = compose(trimmed)
        }
        // …and the backstop, for a name that is long without the prefix having
        // made it so: the template itself is free text in Settings, and a scene
        // or roll off a restored blob is not filtered by a text field either.
        if Self.exceedsBudget(candidate, bytes: byteBudget, units: unitBudget) {
            candidate = Self.truncated(candidate, toBytes: byteBudget,
                                       units: unitBudget)
        }
        return Self.collapseSeparators(candidate) + marker
    }

    /// The marker a shortened name carries: `~` and the name's xxHash64.
    ///
    /// `~` because nothing else in a composed name uses it — `sanitize` leaves
    /// it alone, `collapseSeparators` does not fold it, and it is legal on every
    /// file system involved — so a reader can see where the name was cut.
    /// xxHash64 because the app already computes it for the offload manifests
    /// and it is the digest the DIT world reads.
    static func truncationMarker(for name: String) -> String {
        "~" + XXH64.hex(XXH64.hash(Data(name.utf8)))
    }

    /// `value` cut to fit both budgets, on a CHARACTER boundary.
    ///
    /// Characters rather than bytes or code points, and never `String.prefix`,
    /// which counts characters and bounds nothing. A cut through the middle of
    /// a two-byte Cyrillic letter is not UTF-8 at all: it does not round-trip
    /// through the CSV sidecars, and the name in `takeshot-log.csv` would no
    /// longer match the file it names. Cutting on a Character keeps combining
    /// marks with the letter they belong to as well, so a decomposed name is
    /// not left ending in a floating accent.
    ///
    /// Stops at the first character that does not fit, so it walks the budget's
    /// worth of the string and not the whole of a pasted one.
    static func truncated(_ value: String, toBytes byteLimit: Int,
                          units unitLimit: Int) -> String {
        var result = ""
        var bytes = 0
        var units = 0
        for character in value {
            let size = character.utf8.count
            let span = pathUnits(String(character))
            guard bytes + size <= byteLimit, units + span <= unitLimit else { break }
            result.append(character)
            bytes += size
            units += span
        }
        return result
    }

    /// `value` with trailing characters removed until at least `count` bytes
    /// are gone — and always at least one, so the loop above makes progress
    /// whichever budget is the binding one.
    static func droppingLast(_ value: String, atLeastBytes count: Int) -> String {
        var result = value
        var dropped = 0
        while !result.isEmpty, dropped < max(1, count) {
            dropped += result.removeLast().utf8.count
        }
        return result
    }
}
