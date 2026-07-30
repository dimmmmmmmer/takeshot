import Foundation

/// The two self-dismissing toasts over the footer.
///
/// A toast is for things the operator may miss without cost. Anything that
/// threatens footage is a STICKY alarm instead (`persistentAlert`, see
/// `+CaptureEvents`) — a five-second banner that scrolled past while the
/// operator was lighting the next setup is how a lost take goes unnoticed.
///
/// The timers live here rather than in the observers that start them:
/// `CaptureController.swift` is the state inventory, and everything the type
/// DOES belongs in a domain extension.
extension CaptureController {
    func scheduleErrorDismiss() {
        errorDismissTask?.cancel()
        guard lastError != nil else { return }
        errorDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }

    func scheduleNoticeDismiss() {
        // Every notice starts neutral; a marker toast paints itself right
        // after assigning the text (see `noticeAboutMarker`). Resetting here
        // is what keeps one marker's color off the next, unrelated notice.
        lastNoticeTint = nil
        noticeDismissTask?.cancel()
        guard lastNotice != nil else { return }
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.lastNotice = nil
        }
    }
}
