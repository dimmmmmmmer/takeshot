import TakeShotKit

// The app itself lives in TakeShotKit: a SwiftPM executable target cannot be
// imported by a test target, and the whole application layer — CaptureController,
// the session logic, the mock backend — was unreachable from tests as long as it
// sat here. This file is the entry point and nothing else.
TakeShotApp.main()
