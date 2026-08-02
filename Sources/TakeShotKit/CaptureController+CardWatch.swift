import CaptureCore
import Foundation

/// Cards that mount while the app is running.
///
/// **The rule this file exists to keep.** A card that mounts NEVER starts
/// copying. It raises one non-modal, dismissible line in the takes panel that
/// says what was found and asks; the copy itself still goes through the offload
/// sheet, and the destinations are still chosen by the operator — the source is
/// the only thing pre-filled, because the source is the only thing the app
/// actually knows. Everything here is in service of that: the watch is a
/// notification observer, the scan is read-only, and the one write it performs
/// is the ledger entry that stops it asking twice.
///
/// **And it never asks during a take.** A prompt appearing mid-take is exactly
/// the kind of contention this app is built to avoid, so a mount during a
/// recording is queued and shown when the take closes.
extension CaptureController {
    /// The offering is on unless the operator turned it off. nil is on: the
    /// offer costs nothing and the consent is asked for separately.
    var offersMountedCards: Bool { settings.offerMountedCards != false }

    /// Wired once, from `completeStartup`.
    func startCardWatch() {
        volumeWatch.onMount = { [weak self] volume in
            self?.handleVolumeMount(volume)
        }
        volumeWatch.onUnmount = { [weak self] url in
            self?.handleVolumeUnmount(url)
        }
        offloadedCards.load()
        guard offersMountedCards else { return }
        volumeWatch.start()
    }

    /// The settings toggle, applied. Turning it off takes down the observers AND
    /// clears anything already asked or queued — a switch that leaves the last
    /// prompt on screen has not been turned off as far as the operator is
    /// concerned.
    func applyCardWatchChange(from oldValue: CaptureSettings) {
        guard oldValue.offerMountedCards != settings.offerMountedCards else {
            return
        }
        guard offersMountedCards else {
            volumeWatch.stop()
            cardOffer = nil
            deferredCardOffers.removeAll()
            return
        }
        volumeWatch.start()
    }

    // MARK: - a volume appears

    /// A volume mounted. Decide off the MainActor whether it is a card: the walk
    /// is a few hundred milliseconds of metadata I/O on a full card, and the
    /// window must not stall for it while a take is rolling.
    func handleVolumeMount(_ volume: MountedVolume) {
        guard offersMountedCards, !isExcludedVolume(volume) else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let candidate = CardScan.inspect(volume) else { return }
            await self?.considerCard(candidate)
        }
    }

    /// The scan came back with something card-shaped. Whether to ASK about it.
    func considerCard(_ candidate: CardCandidate) {
        guard offersMountedCards else { return }
        // Remembered whether or not it is offered: a card the operator offloads
        // by hand through the sheet still has to be matched back to its ledger
        // entry when the run finishes.
        seenCards[Self.comparablePath(candidate.url)] = candidate
        guard !ignoredCardKeys.contains(candidate.key),
              !offloadedCards.isSettled(candidate),
              cardOffer?.key != candidate.key,
              !deferredCardOffers.contains(where: { $0.key == candidate.key })
        else { return }
        // One prompt at a time, and none at all during a take.
        guard !isRecording, cardOffer == nil else {
            deferredCardOffers.append(candidate)
            return
        }
        cardOffer = candidate
    }

    /// The take closed (or the current prompt was answered): ask about whatever
    /// mounted in the meantime.
    func drainDeferredCardOffers() {
        guard offersMountedCards, !isRecording, cardOffer == nil else { return }
        // A card can be settled while it sits in the queue — offloaded through
        // the sheet by hand, or silenced from another prompt for the same disk.
        deferredCardOffers.removeAll {
            ignoredCardKeys.contains($0.key) || offloadedCards.isSettled($0)
        }
        guard !deferredCardOffers.isEmpty else { return }
        cardOffer = deferredCardOffers.removeFirst()
    }

    /// The card was pulled. A prompt about a disk that is no longer there is
    /// worse than no prompt — the operator clicks Offload and gets a file panel
    /// pointing at nothing.
    func handleVolumeUnmount(_ url: URL) {
        let path = Self.comparablePath(url)
        seenCards.removeValue(forKey: path)
        deferredCardOffers.removeAll {
            Self.comparablePath($0.url) == path
        }
        guard cardOffer.map({ Self.comparablePath($0.url) }) == path else {
            return
        }
        cardOffer = nil
        drainDeferredCardOffers()
    }

    // MARK: - the three answers

    /// Yes. The normal offload sheet, with this card already in the source slot.
    ///
    /// The DESTINATIONS are not guessed and never will be: the sheet seeds them
    /// from the rig the operator saved last time, and picking where footage lands
    /// is not a decision an app gets to make on a mount notification.
    func acceptCardOffer() {
        guard let offer = cardOffer else { return }
        showOffloadSheet()
        // A disk job already running refuses the sheet (or reopens the running
        // one) and says so. The offer stays up in that case rather than being
        // silently spent — the card still has not been copied.
        guard offloadSheetPresented, !offload.isRunning else { return }
        cardOffer = nil
        offload.source = offer.url
        drainDeferredCardOffers()
    }

    /// Not now. Gone for this session; the card is offered again next launch.
    func ignoreCardOffer() {
        guard let offer = cardOffer else { return }
        ignoredCardKeys.insert(offer.key)
        cardOffer = nil
        drainDeferredCardOffers()
    }

    /// Never — this disk is not a card the operator wants offering. Persisted,
    /// and undone from Settings, which is the only way back (see
    /// `OffloadedCardLedger.clear`).
    func neverOfferCardAgain() {
        guard let offer = cardOffer else { return }
        offloadedCards.suppress(offer)
        ignoredCardKeys.insert(offer.key)
        cardOffer = nil
        drainDeferredCardOffers()
    }

    // MARK: - what settles a card

    /// A finished run, as the ledger sees it.
    ///
    /// Only a FULLY VERIFIED run settles a card. A run that failed, was stopped,
    /// or came back with mismatches leaves the card exactly as unasked-about as
    /// it was — that card must be offered again when it comes back, because it
    /// is precisely the one nobody should assume is copied.
    func noteOffloadedCard(_ report: OffloadReport) {
        guard report.isFullyVerified,
              let candidate = seenCards[Self.comparablePath(report.run.source)]
        else { return }
        offloadedCards.markOffloaded(candidate)
    }

    // MARK: - volumes that are never cards

    /// Volumes the watch does not even scan.
    ///
    /// The boot volume, anything reached over the network, the system's own
    /// hidden mounts — and the app's OWN disks: the record folder's volume and
    /// every destination the operator has saved. Offering to copy a card off the
    /// disk the copies land on is the one wrong guess that would cost more than
    /// a click to undo.
    func isExcludedVolume(_ volume: MountedVolume) -> Bool {
        let path = Self.comparablePath(volume.url)
        guard path != "/", volume.isLocal, volume.isBrowsable else { return true }
        return ownFolders.contains { Self.folder($0, isOn: path) }
    }

    /// Folders this app writes to: the record folder and everywhere an offload
    /// has been aimed.
    var ownFolders: [URL] {
        var folders = [destinationRoot]
        folders += (settings.offloadDestinationPaths ?? [])
            .map { URL(fileURLWithPath: $0) }
        if let backup = settings.backupPath {
            folders.append(URL(fileURLWithPath: backup))
        }
        return folders
    }

    /// Is `folder` on the volume mounted at `path`? By path prefix, which is
    /// what a mount point is — comparing volume UUIDs would need the folder to
    /// exist, and a destination the operator saved last week may not.
    static func folder(_ folder: URL, isOn path: String) -> Bool {
        let target = comparablePath(folder)
        let root = path.hasSuffix("/") ? path : path + "/"
        return target == path || target.hasPrefix(root)
    }

    /// The path two file URLs are compared by here.
    ///
    /// `standardizedFileURL` is the wrong tool and cost a debugging session:
    /// it strips a leading `/private` only when what is left still names
    /// something that EXISTS. A mounted volume exists and a destination folder
    /// the operator picked last week may not, so the two standardize to
    /// different roots and never compare equal — the volume the copies land on
    /// would then be offered as a card. `standardized` is purely lexical and
    /// treats both the same.
    static func comparablePath(_ url: URL) -> String {
        url.standardized.path
    }
}
