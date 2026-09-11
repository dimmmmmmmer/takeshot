import CaptureCore
import SwiftUI

/// **The destination's own check** — the button under the folder list, what it
/// says, and the list of files that are not all right (owner: "ну и чтобы
/// какая-то у нас проверка типа как после копий была что все файлы точно
/// отрендерены как надо").
///
/// Split out of `DailiesFilesTab` when that face reached the length at which a
/// type stops being readable top to bottom, and a coherent cut: everything
/// here answers about the FOLDER rather than about the queue — including runs
/// from other days, which is the whole reason an operator presses it.
extension DailiesFilesTab {
    /// **Is everything in that folder really there and really finished?**
    /// (owner: "ну и чтобы какая-то у нас проверка типа как после копий была
    /// что все файлы точно отрендерены как надо").
    ///
    /// Under the destination rather than beside Start, because it is a
    /// question about the FOLDER and not about the queue — it answers for
    /// every run that ever wrote there, including the ones interrupted on
    /// other days.
    @ViewBuilder var check: some View {
        HStack(spacing: OffloadChrome.rowSpacing) {
            Button(L("dailies_verify")) { model.verifyDestination() }
                .disabled(!controller.canVerifyDailies)
            if model.isVerifying {
                Text(L("dailies_verify_running")).offloadText(.caption)
            } else if !model.verifyFindings.isEmpty {
                Text(checkSummary).offloadText(.caption)
            }
            Spacer(minLength: 4)
        }
        // Every file that is not all right, by name: a count alone sends an
        // assistant to compare a folder against a journal by hand.
        ForEach(model.verifyFindings.filter(\.isFault), id: \.output) { finding in
            Label("\(finding.output) — \(Self.words(for: finding.verdict))",
                  systemImage: "exclamationmark.triangle")
                .offloadText(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A verdict in the operator's own language.
    ///
    /// A switch with literal keys and not `"dailies_verdict_" + rawValue`:
    /// `LocalizationTests` reads the sources for `L("…")` and cannot follow a
    /// key that is assembled, so a built key is a string that silently stops
    /// being translated. The same reason every other enum in this app spells
    /// its keys out.
    static func words(for verdict: DailiesVerify.Verdict) -> String {
        switch verdict {
        case .ok: return L("dailies_verdict_ok")
        case .missing: return L("dailies_verdict_missing")
        case .resized: return L("dailies_verdict_resized")
        case .unreadable: return L("dailies_verdict_unreadable")
        case .short: return L("dailies_verdict_short")
        case .silent: return L("dailies_verdict_silent")
        case .unchecked: return L("dailies_verdict_unchecked")
        }
    }

    var checkSummary: String {
        let faults = model.verifyFindings.filter(\.isFault).count
        return faults == 0
            ? L("dailies_verify_clean",
                localizedCount(model.verifyFindings.count, .file))
            : L("dailies_verify_faults", faults, model.verifyFindings.count,
                model.verifyFindings.first(where: \.isFault)?.output ?? "")
    }
}
