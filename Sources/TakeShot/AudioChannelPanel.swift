import AVFoundation
import SwiftUI

/// Крупная панель аудиоканалов по центру плеера: большие метры с dB-цифрами,
/// клик по каналу включает/выключает его запись.
struct AudioChannelPanel: View {
    @EnvironmentObject private var controller: CaptureController

    private let range: ClosedRange<Float> = -60...0

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(L("audio_panel_title"))
                    .font(.headline)
                Spacer()
                Button {
                    controller.showAudioPanel = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            HStack(alignment: .bottom, spacing: 8) {
                dbScale
                ForEach(Array(controller.audioLevels.enumerated()), id: \.offset) { index, level in
                    channelColumn(index: index, level: level)
                }
                dbScale
            }
            Text(L("audio_panel_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
        .shadow(radius: 18)
    }

    private func channelColumn(index: Int, level: Float) -> some View {
        let enabled = controller.isChannelEnabled(index)
        return VStack(spacing: 3) {
            Text(level <= -99 ? "-∞" : String(format: "%.0f", level))
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.secondary)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.black.opacity(0.5))
                RoundedRectangle(cornerRadius: 2)
                    .fill(AudioMeterView.color(for: level))
                    .frame(height: 130 * fraction(of: level))
                    .animation(.linear(duration: 0.07), value: level)
            }
            .frame(width: 16, height: 130)
            .opacity(enabled ? 1 : 0.25)
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(enabled ? .primary : .tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { controller.toggleAudioChannel(index) }
        .help(enabled ? L("channel_on_help") : L("channel_off_help"))
    }

    /// Шкала dB сбоку от метров (0 вверху, -60 внизу).
    private var dbScale: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 12) // компенсация строки с цифрой dB над столбиком
            VStack(alignment: .trailing, spacing: 0) {
                ForEach([0, -12, -24, -36, -48, -60], id: \.self) { mark in
                    Text("\(mark)")
                        .font(.system(size: 7).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity, alignment: mark == 0 ? .top : (mark == -60 ? .bottom : .center))
                }
            }
            .frame(height: 130)
            Spacer().frame(height: 14) // компенсация номера канала снизу
        }
    }

    private func fraction(of level: Float) -> CGFloat {
        let clamped = min(max(level, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

/// Фулскрин-окно живого сигнала: картинка + подвал управления по ховеру снизу.
struct LiveFullscreenView: View {
    @EnvironmentObject private var controller: CaptureController
    @State private var footerHover = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                Color.black
                LiveMirrorView(layer: controller.pipeline.fullscreenLayer)
                if !footerHover {
                    Button {
                        controller.toggleLiveFullscreen()
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 14))
                            .padding(8)
                            .background(.black.opacity(0.5),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                }
            }
            .overlay(alignment: .bottom) {
                if footerHover {
                    BottomBarView()
                        .background(.ultraThinMaterial,
                                    in: RoundedRectangle(cornerRadius: 18))
                        .padding(.horizontal, 60)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    withAnimation(.easeOut(duration: 0.15)) {
                        footerHover = point.y > geo.size.height - 150
                    }
                case .ended:
                    withAnimation(.easeOut(duration: 0.15)) { footerHover = false }
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct LiveMirrorView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .clear
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Фулскрин-окно плейбека: только картинка и транспорт.
struct PlaybackFullscreenView: View {
    @EnvironmentObject private var controller: CaptureController

    @State private var transportHover = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                PlaybackContent(target: .fullscreen)
            }
            .overlay(alignment: .bottom) {
                if transportHover {
                    TransportBar(player: controller.player)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 60)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    withAnimation(.easeOut(duration: 0.15)) {
                        transportHover = point.y > geo.size.height - 130
                    }
                case .ended:
                    withAnimation(.easeOut(duration: 0.15)) { transportHover = false }
                }
            }
        }
        .ignoresSafeArea()
    }
}
