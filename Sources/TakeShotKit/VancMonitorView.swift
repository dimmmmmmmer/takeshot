import CaptureCore
import SwiftUI

/// VANC packet monitor: which DID/SDID arrive in the signal, how many, and what's
/// inside. The main on-set tool for figuring out what metadata a given camera
/// emits, so a parser can be added for it.
struct VancMonitorView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.vancStats.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 32))
                    Text(L("vanc_empty"))
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Table(controller.vancStats) {
                    TableColumn(L("vanc_col_id")) { stat in
                        Text(stat.key)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(70)
                    TableColumn(L("vanc_col_desc")) { stat in
                        Text(Self.describe(did: stat.did, sdid: stat.sdid))
                    }
                    .width(min: 120, ideal: 170)
                    TableColumn(L("vanc_col_count")) { stat in
                        Text("\(stat.count)").monospacedDigit()
                    }
                    .width(70)
                    TableColumn(L("vanc_col_line")) { stat in
                        Text("\(stat.lastLine)").monospacedDigit()
                    }
                    .width(50)
                    TableColumn(L("vanc_col_data")) { stat in
                        Text(stat.lastDataHex)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 240)
        // No `navigationTitle`: on a `Window` scene it writes NSWindow.title and
        // SwiftUI puts titleVisibility back to .visible when it does, which is
        // how this window kept showing a title strip the scopes window does not.
        // The scene carries the localized name instead (see TakeShotApp), so the
        // Window menu still lists it, and `monolithicWindowChrome` re-asserts
        // the chrome without depending on when the key notification lands.
        .monolithicWindowChrome()
    }

    static func describe(did: UInt8, sdid: UInt8) -> String {
        switch (did, sdid) {
        case (0x51, 0x52): return "Blackmagic tally"
        case (0x51, 0x53): return "Blackmagic camera control"
        case (0x60, 0x60): return "Timecode (RP188/ATC)"
        case (0x61, 0x01): return "Captions (CEA-708)"
        case (0x61, 0x02): return "Captions (CEA-608)"
        case (0x41, 0x05): return "AFD/Bar data"
        case (0x45, 0x01): return "Audio metadata"
        case (0x43, _): return "SMPTE RDD/ITU"
        default: return L("vanc_unknown")
        }
    }
}
