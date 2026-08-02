import Foundation
import TakeShotKit

// The app itself lives in TakeShotKit: a SwiftPM executable target cannot be
// imported by a test target, and the whole application layer — CaptureController,
// the session logic, the mock backend — was unreachable from tests as long as it
// sat here. This file is the entry point and nothing else.

// …with one thing that has to happen BEFORE the entry point: a second copy of
// TakeShot would fight the first for the DeckLink board and the record folder,
// and by the time the scene graph exists the controller has already adopted a
// board and started capturing on it. See `SingleInstanceGuard` — this is inert
// for a bare `swift build` binary, which has no bundle identifier.
if TakeShotApp.handOffToRunningInstance() { exit(0) }

TakeShotApp.main()
