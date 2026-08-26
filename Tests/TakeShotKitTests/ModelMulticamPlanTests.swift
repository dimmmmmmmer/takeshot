import CaptureCore
import Foundation
import Testing

@testable import TakeShotKit

/// Which board becomes which camera, and whether a second camera is offered
/// at all.
///
/// docs/coverage.md lists `setMulticam`'s hardware arm as out of reach, and the
/// reason stands: starting a channel means constructing a
/// `DeckLinkBackendAdapter`, which installs a process-wide hot-plug callback and
/// adopts whatever board is attached — safe on a runner with no SDK and unsafe
/// on the developer's machine, which is not a difference a suite may depend on.
///
/// The PLAN in front of it is not that, and it is the part worth defending. A
/// camera label goes through `NamingEngine` into the FILE NAMES, so a board that
/// answered to a different letter between two sessions of the same shoot is a
/// day of footage that will not sort against the other day's — and the operator
/// finds out in the edit.
@Suite @MainActor struct ModelMulticamPlanTests {
    private func board(_ id: String, _ name: String) -> CaptureDeviceInfo {
        CaptureDeviceInfo(id: "decklink:\(id)", name: name)
    }

    private let demo = CaptureDeviceInfo(id: "mock:demo", name: "Demo camera")

    private func plan(_ boards: [CaptureDeviceInfo], selected: String?,
                      main: String = "A") -> [(deviceID: String, label: String)] {
        CaptureController.multicamPlan(boards: boards, selected: selected,
                                       mainLabel: main)
    }

    // MARK: - the letters

    /// The main camera keeps its letter and the others follow it in device
    /// order. With A on the selected board the rest are B, C, D.
    @Test func theOtherBoardsFollowTheMainCamerasLetter() {
        let boards = [board("0", "UltraStudio 1"), board("1", "UltraStudio 2"),
                      board("2", "UltraStudio 3"), board("3", "UltraStudio 4")]
        let made = plan(boards, selected: "decklink:0")
        #expect(made.map(\.label) == ["B", "C", "D"])
        #expect(made.map(\.deviceID) == ["1", "2", "3"])
    }

    /// The main camera is not always A — an operator on the second unit starts
    /// at C — and the extras follow from wherever it is rather than from the
    /// front of the alphabet. Two units both writing B is two cards that
    /// collide on ingest.
    @Test func theLettersFollowTheMainCameraWhereverItStarts() {
        let boards = [board("0", "one"), board("1", "two"), board("2", "three")]
        #expect(plan(boards, selected: "decklink:0", main: "C").map(\.label)
                == ["D", "E"])
        // and it wraps rather than running off the end of the alphabet
        #expect(plan(boards, selected: "decklink:0", main: "Z").map(\.label)
                == ["A", "B"])
    }

    /// The SELECTED board is the main camera and never gets a second channel
    /// of its own — a board opened twice is a board that fails to open the
    /// second time, mid-shoot.
    @Test func theSelectedBoardIsNeverGivenAChannelOfItsOwn() {
        let boards = [board("0", "one"), board("1", "two"), board("2", "three")]
        let made = plan(boards, selected: "decklink:1")
        #expect(made.map(\.deviceID) == ["0", "2"])
        #expect(!made.contains { $0.deviceID == "1" })
    }

    /// The plan carries the RAW device id — what `CameraChannel` opens — not
    /// the prefixed one the device list shows.
    @Test func thePlanCarriesTheIdTheBoardIsOpenedBy() {
        let made = plan([board("0", "one"), board("14A3F2", "two")],
                        selected: "decklink:0")
        #expect(made.map(\.deviceID) == ["14A3F2"])
    }

    /// One board is not multicam, and neither is none.
    @Test func aSingleBoardMakesNoExtraCameras() {
        #expect(plan([board("0", "only")], selected: "decklink:0").isEmpty)
        #expect(plan([], selected: nil).isEmpty)
    }

    /// With nothing selected every board is an extra. That state is real — the
    /// device list arrives before a choice is restored — and the answer that
    /// matters is that it does not crash or claim board 0 twice.
    @Test func nothingSelectedLeavesEveryBoardAnExtra() {
        let boards = [board("0", "one"), board("1", "two")]
        let made = plan(boards, selected: nil)
        #expect(made.map(\.deviceID) == ["0", "1"])
        #expect(Set(made.map(\.label)).count == made.count, "two cameras share a letter")
    }

    // MARK: - whether the badge is offered

    /// The badge over the player and the plan behind it read the same list.
    @Test func theBadgeIsOfferedWhenThereIsASecondBoard() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.devices = [self.demo]
            #expect(!controller.multicamOffered)

            controller.devices = [self.demo, self.board("0", "one")]
            #expect(!controller.multicamOffered, "one board is not multicam")

            controller.devices = [self.demo, self.board("0", "one"),
                                  self.board("1", "two")]
            #expect(controller.multicamOffered)
            #expect(controller.deckLinkDevices.count == 2,
                    "the demo source counted as a board")
        }
    }

    /// The demo source can start a second MOCK camera — that is how the grid is
    /// exercised with no hardware — and it deliberately does NOT light the
    /// badge. `MockCaptureBackend` is in every build's device list, so a badge
    /// that counted it would put a multicam button on the player of every
    /// downloaded copy of the app.
    @Test func theDemoSourceDoesNotLightTheBadge() async throws {
        try await ControllerHarness.run { controller, _ in
            controller.devices = [self.demo]
            controller.selectedDeviceID = self.demo.id
            #expect(controller.isMockSelected)
            #expect(!controller.multicamOffered)
        }
    }
}
