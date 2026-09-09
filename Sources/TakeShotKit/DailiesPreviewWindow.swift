import CaptureCore
import SwiftUI

/// **The burn-in arrangement, big** (owner: "а превью визуальное было бы
/// хорошо иметь возможность видеть крупнее, на весь экран например").
///
/// A window rather than a bigger box inside the sheet: the sheet is 670pt
/// wide and has to stay inside a window that may be 620 tall, and what the
/// operator wants to check at this size — whether a watermark's lettering
/// reads over the picture, whether a plate is hiding a face — is a question
/// about the frame at frame size. The green button puts it on a whole display.
///
/// It renders through `DailiesOverlay.previewImage`, the same call the small
/// preview makes and the same code that burns the frame. Two previews that
/// could disagree would be worse than one.
struct DailiesPreviewWindowView: View {
    @EnvironmentObject private var controller: CaptureController

    var body: some View {
        DailiesBigPreview(model: controller.dailies,
                          still: controller.dailies.previewStill)
            .monolithicWindowChrome()
    }
}

/// The picture itself, sized by whatever it is given.
///
/// `GeometryReader` and not a fixed raster: the point of this window is that
/// the operator can make it as big as the display, and a preview rendered at
/// one size and stretched to another would be showing them the wrong strip
/// height — the very thing the small preview's 2x raster exists to get right.
struct DailiesBigPreview: View {
    @ObservedObject var model: DailiesQueueModel
    /// Taken in, like the small preview's — see there.
    var still: CGImage?

    /// A cap on the raster this renders, whatever the window's size. The
    /// strips scale with the height, so past a full 1080 there is nothing more
    /// to see and every redraw is composing a 4K bitmap on a main-actor pass.
    static let maxHeight: CGFloat = 1080

    var body: some View {
        GeometryReader { geo in
            let raster = Self.raster(for: geo.size)
            ZStack {
                Color.black
                if let image = DailiesOverlay.previewImage(
                    size: raster, texts: texts,
                    background: CGColor(gray: 0.22, alpha: 1),
                    backgroundImage: still) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.black)
    }

    /// The 16:9 raster to render for a window of `size`, capped.
    static func raster(for size: CGSize) -> CGSize {
        let height = min(maxHeight, max(180, size.height.rounded()))
        return CGSize(width: (height * 16 / 9).rounded(), height: height)
    }

    private var texts: DailiesOverlay.Texts {
        model.burnins.overlayTexts(for: DailiesItem(
            source: URL(fileURLWithPath: "/"), outputName: "",
            clipName: "A001C001", projectLine: "PROJECT",
            dateText: "12.07.26"))
    }
}
