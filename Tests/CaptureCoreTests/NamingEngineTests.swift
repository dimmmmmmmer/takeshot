import Foundation
import Testing
@testable import CaptureCore

struct NamingEngineTests {
    private var date: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 14
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test func fullTemplate() {
        let engine = NamingEngine(template: "{scene}_T{take}_{cam}_{tc}")
        let name = engine.fileName(for: NamingContext(
            scene: "12A", take: 3, camera: "A",
            timecode: Timecode(hours: 10, minutes: 20, seconds: 30, frames: 15, fps: 25)))
        #expect(name == "12A_T03_A_10.20.30.15")
    }

    @Test func missingValuesCollapse() {
        let engine = NamingEngine(template: "{scene}_T{take}_{cam}_{tc}")
        let name = engine.fileName(for: NamingContext(scene: "5", take: 1))
        #expect(name == "5_T01")
    }

    @Test func sanitizesForbiddenCharacters() {
        let engine = NamingEngine(template: "{scene}_{clipname}")
        let name = engine.fileName(for: NamingContext(
            scene: "INT/КУХНЯ: день", clipName: "clip*01?"))
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(!name.contains("*"))
        #expect(!name.contains("?"))
        #expect(name == "INT_КУХНЯ_день_clip_01")
    }

    @Test func unknownPlaceholderRemoved() {
        let engine = NamingEngine(template: "{scene}_{unknown}_T{take}")
        let name = engine.fileName(for: NamingContext(scene: "3", take: 2))
        #expect(name == "3_T02")
    }

    @Test func emptyResultFallsBack() {
        let engine = NamingEngine(template: "{reel}")
        #expect(engine.fileName(for: NamingContext()) == "untitled")
    }

    @Test func datePlaceholder() {
        let engine = NamingEngine(template: "{date}_{scene}")
        let name = engine.fileName(for: NamingContext(date: date, scene: "7"))
        #expect(name == "2026-07-14_7")
    }

    @Test func relativeDirectory() {
        let engine = NamingEngine(template: "{scene}")
        let dir = engine.relativeDirectory(for: NamingContext(
            project: "My Film", date: date, scene: "12A"))
        #expect(dir == "My_Film/2026-07-14/12A")
    }
}
