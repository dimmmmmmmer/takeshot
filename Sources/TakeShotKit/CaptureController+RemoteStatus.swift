import CaptureCore
import Foundation

/// What the phone shows, and the four commands it can send back.
///
/// Split out of `+Remote`, which brings the server up and down. The status is
/// built on the MainActor and handed over as a value — the server never reads
/// controller state — and every command lands on the method the on-screen
/// button calls, so there is no second path to the recorder.
extension CaptureController {
    // MARK: - status

    /// What the phone shows. Built here on the MainActor and handed over as a
    /// value — the server never reads controller state.
    func remoteStatus() -> RemoteStatus {
        var status = RemoteStatus()
        status.timecode = live.currentTimecode?.description ?? ""
        status.recording = isRecording
        status.capturing = isCapturing
        status.format = signalFormat?.name ?? ""
        // While a take rolls, the name being written is the pending one — the
        // same string the collision warning is about. Afterwards it is the take
        // that just landed, which is also the one the ratings apply to.
        status.takeName = isRecording
            ? pendingTakeName : (takes.last?.displayName ?? "")
        // The card on the phone is about the last take that LANDED, whatever
        // the header above it says: it carries that take's frame, and the two
        // rating buttons already act on that take through `toggleLastRating`.
        status.lastTakeName = takes.last?.displayName ?? ""
        status.lastTakeID = takes.last.map { $0.id.uuidString } ?? ""
        status.rating = (takes.last?.rating ?? .none).rawValue
        status.diskFreeGB = remoteDiskFreeGB
        status.markerCount = remoteMarkerCount
        // the page shows/hides its non-REC controls on this — see remote.html
        status.mode = viewerMode == .playback ? "playback" : "record"
        // Main camera first, extras in channel order — the same indexing the
        // multiview frames carry in their camera byte. Each tile's REC light
        // is its OWN pipeline's state: in multicam the boards record apart,
        // and a B-cam whose writer died must not glow red on A-cam's word.
        status.cameras = [RemoteStatus.CameraState(
            name: settings.naming.cameraLabel, recording: isRecording)]
            + extraChannels.map {
                RemoteStatus.CameraState(name: $0.camLabel,
                                         recording: $0.isRecording)
            }
        return status
    }

    /// The count the phone's footer shows — the markers of whatever a marker
    /// press would land on, mirroring `addMarker()`'s own routing branch for
    /// branch (playback clip first, then the take in progress).
    ///
    /// The old payload counted `takes.last` whenever nothing was recording, so
    /// a marker placed on the clip being reviewed — including from the phone
    /// itself — never changed the number, which is the "shows 0 even when I
    /// place one" of owner item 28.
    private var remoteMarkerCount: Int {
        if viewerMode == .playback, playbackURL != nil {
            return playbackMarkers.count
        }
        if isRecording { return recordingMarkers.count }
        return takes.last?.markers.count ?? 0
    }

    /// Push the status now rather than at the next tick — a button that lights
    /// up a quarter of a second late reads as a dropped press.
    func pushRemoteStatus() {
        remoteServer?.broadcast(remoteStatus())
    }

    /// The script page's table: every take the panel lists, with the fields a
    /// scripty logs. Built on the MainActor and handed over as a value, like
    /// the status — the server never reads controller state.
    func remoteTakeLog() -> RemoteTakeLog {
        RemoteTakeLog(entries: takes.map { take in
            RemoteTakeLog.Entry(id: take.id.uuidString,
                                name: take.displayName,
                                timecode: take.startTimecode?.description ?? "",
                                durationSeconds: take.durationSeconds,
                                rating: take.rating.rawValue,
                                comment: take.comment,
                                scene: take.slate.scene,
                                shot: take.slate.shot,
                                // empty, not "0": the page shows an unlogged
                                // take number as a blank field
                                take: take.slate.take > 0
                                    ? String(take.slate.take) : "",
                                poster: RemoteTakeLog.Entry.posterReference(
                                    takeID: take.id.uuidString))
        })
    }

    /// Push the take log now rather than at the next tick — an edit the
    /// scripty just made has to come back as pushed state, or the page reads
    /// its own save as lost.
    func pushRemoteTakeLog() {
        remoteServer?.broadcastTakeLog(remoteTakeLog())
    }

    // MARK: - the poster

    /// One take's frame as JPEG bytes, or nil while there is none. An empty
    /// `id` means the last take that landed — the operator page's card.
    ///
    /// The takes panel's own thumbnail, re-encoded. A second decoder for the
    /// same frame would be a second thing to keep in step with a file that
    /// finalizes asynchronously, and it would decode a take the operator is
    /// already looking at twice. The contact sheet's export-time decode was the
    /// other candidate and is the wrong one here: it renders at print size for
    /// a document, has no cache a phone could hit, and repeats none of the
    /// retry-while-the-file-finalizes that `requestThumbnail` already does.
    ///
    /// Asking also STARTS the decode when the cache has nothing: the phone's
    /// 404 is what sets up the answer to its next attempt, so a take recorded
    /// while nobody has the takes panel in thumbnail mode still gets a poster.
    ///
    /// Nothing here touches the capture queue, and nothing here decodes: the
    /// frame is already an `NSImage` in `thumbnails` or it is not served yet.
    func remoteTakePoster(id: String = "") -> Data? {
        guard let take = id.isEmpty
            ? takes.last : takes.first(where: { $0.id.uuidString == id })
        else { return nil }
        if let cached = remotePosterJPEG[take.id] { return cached }
        guard let image = thumbnails[take.id] else {
            requestThumbnail(for: take)
            return nil
        }
        guard let jpeg = RemotePoster.jpeg(from: image) else { return nil }
        storeRemotePoster(jpeg, for: take.id)
        return jpeg
    }

    /// Keep the encoded bytes, bounded. A take's frame never changes once it is
    /// decoded, and the script page asks for one per ROW: re-encoding the whole
    /// day's log on every phone that opens the page would put that work on the
    /// MainActor, which is where the REC button lives.
    private func storeRemotePoster(_ jpeg: Data, for id: Take.ID) {
        remotePosterJPEG[id] = jpeg
        remotePosterOrder.removeAll { $0 == id }
        remotePosterOrder.append(id)
        while remotePosterOrder.count > RemotePoster.cacheLimit {
            remotePosterJPEG[remotePosterOrder.removeFirst()] = nil
        }
    }

    func startRemoteStatusPump() {
        remoteStatusTask?.cancel()
        remoteStatusTask = Task { [weak self] in
            var ticks = 0
            var lastSent: RemoteStatus?
            var lastTakeLog: RemoteTakeLog?
            while !Task.isCancelled {
                guard let self else { return }
                if ticks % Self.remoteDiskTicks == 0 { self.sampleRemoteDisk() }
                let status = self.remoteStatus()
                if status != lastSent || ticks % Self.remoteHeartbeatTicks == 0 {
                    self.remoteServer?.broadcast(status)
                    lastSent = status
                }
                // The take log goes out only when it changed: it can be a whole
                // day of takes, and the status heartbeat already proves the
                // socket alive. A finalize, a rating, an edit — from either
                // side — all land here within a tick, which is how the script
                // page updates without a refresh.
                let takeLog = self.remoteTakeLog()
                if takeLog != lastTakeLog {
                    self.remoteServer?.broadcastTakeLog(takeLog)
                    lastTakeLog = takeLog
                }
                ticks &+= 1
                try? await Task.sleep(for: Self.remoteTick)
            }
        }
    }

    private func sampleRemoteDisk() {
        let values = try? destinationRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else {
            // The volume is gone. -1 shows as a dash on the phone rather than
            // as a confident 0.0 GB.
            remoteDiskFreeGB = -1
            return
        }
        remoteDiskFreeGB = Double(free) / 1_000_000_000
    }

    // MARK: - commands

    /// One command from a phone, on the MainActor.
    func perform(remote command: RemoteCommand) {
        switch command {
        case .hello, .multiview:
            // hello is the PIN handshake and multiview is a per-connection
            // subscription — the server settles both itself, so neither
            // arrives here with any work left to do.
            break
        case .rec:
            // The same guard the on-screen button carries: with no capture
            // running there is nothing to record, and the pipeline would take
            // the press and sit on it.
            guard isCapturing else { return }
            toggleManualRecord()
        case .marker:
            addMarker()
        case .good:
            toggleLastRating(.good)
        case .bad:
            toggleLastRating(.bad)
        case .rate(let takeID, let rating):
            editTake(takeID) { setRating(rating, for: $0) }
        case .comment(let takeID, let text):
            editTake(takeID) { setComment(text, for: $0) }
        case .slate(let takeID, let slate):
            // The same method the panel's own popover calls, so the sidecar
            // rewrite and the "never touch the recorded file" rule come from
            // one place (see CaptureController+Slate).
            editTake(takeID) { setSlate(slate, for: $0) }
        }
        pushRemoteStatus()
        // Edits and finalizes both reshape the table the script page shows;
        // pushing it with the status keeps a tap's echo inside a beat instead
        // of a quarter-second behind it.
        pushRemoteTakeLog()
    }

    /// Run one edit against the take a page-sent id names. The scripty's tap
    /// lands on the method the row's own controls call, so the CSV rewrite
    /// and the panel update come from there. A take that is gone (deleted
    /// between the push and the tap) is silently nothing — the next push
    /// shows the page why.
    private func editTake(_ id: String, _ edit: (Take) -> Void) {
        guard let take = takes.first(where: { $0.id.uuidString == id }) else {
            return
        }
        edit(take)
    }
}
