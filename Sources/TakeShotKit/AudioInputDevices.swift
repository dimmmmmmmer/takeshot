import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// The device layer for the external (USB) audio input, in one file on
/// purpose: what input devices exist, how the app learns they came and went,
/// and the capture wrapper for one of them. Everything above this layer —
/// `ExternalAudioSource`, the controller, the pipeline — talks to the two
/// protocols, so the tests inject fakes here and never enumerate (let alone
/// open) the machine's real audio devices.
///
/// CoreAudio does the listing and the hot-plug watch (AVCaptureDevice's
/// discovery can't see the device set change without KVO on a session), and
/// AVCaptureSession does the capture itself — the simplest path to timestamped
/// PCM with a per-device disconnect notification for device-gone detection.

/// One recordable audio input (USB interface, aggregate, built-in mic).
struct AudioInputDeviceInfo: Identifiable, Equatable {
    var id: String { uid }
    var uid: String
    var name: String
    /// Stated so the UI can be honest about what the device offers — USB
    /// interfaces run anywhere from 2 to 32 channels.
    var channelCount: Int
}

/// A running capture of one input device. `onBuffer` delivers the device's
/// NATIVE format plus the host-clock timestamp of the buffer's first frame,
/// serially on the device's own queue; `ExternalAudioSource` converts from
/// there. `onDeviceGone` fires when the hardware disappears mid-capture.
protocol AudioCaptureDevice: AnyObject {
    var uid: String { get }
    var channelCount: Int { get }
    var onBuffer: ((AVAudioPCMBuffer, CMTime) -> Void)? { get set }
    var onDeviceGone: (() -> Void)? { get set }
    func start() throws
    func stop()
}

/// Where the controller gets its input devices. A protocol for the same
/// reason the backend list is injected: the real provider touches the
/// machine's hardware, and no headless test may depend on what happens to be
/// plugged into the runner.
protocol AudioInputDeviceProviding: AnyObject {
    func list() -> [AudioInputDeviceInfo]
    /// Fire `onChange` on the main queue whenever the device set changes.
    func startWatching(onChange: @escaping () -> Void)
    func makeCaptureDevice(uid: String) -> AudioCaptureDevice?
}

/// The real thing. Construction is inert — nothing touches CoreAudio until
/// `list`, `startWatching` or `makeCaptureDevice` is actually called.
final class SystemAudioInputProvider: AudioInputDeviceProviding {
    func list() -> [AudioInputDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            let channels = Self.inputChannelCount(id)
            guard channels > 0,
                  let uid = AudioOutputDevices.stringProperty(
                    id, kAudioDevicePropertyDeviceUID),
                  let name = AudioOutputDevices.stringProperty(
                    id, kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDeviceInfo(uid: uid, name: name,
                                        channelCount: channels)
        }
    }

    func startWatching(onChange: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address,
            DispatchQueue.main) { _, _ in onChange() }
    }

    func makeCaptureDevice(uid: String) -> AudioCaptureDevice? {
        SystemAudioCaptureDevice(uid: uid)
    }

    /// Total input channels across the device's input streams; 0 — an
    /// output-only device, which the picker must not offer.
    private static func inputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr
        else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// AVCaptureSession around one input device. Buffers arrive on the session's
/// delegate queue already stamped with the host clock, and the per-device
/// disconnect notification is the device-gone signal the controller needs.
final class SystemAudioCaptureDevice: NSObject, AudioCaptureDevice,
                                      AVCaptureAudioDataOutputSampleBufferDelegate {
    enum StartError: Error {
        case cannotBuildSession
    }

    let uid: String
    let channelCount: Int
    var onBuffer: ((AVAudioPCMBuffer, CMTime) -> Void)?
    var onDeviceGone: (() -> Void)?

    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "takeshot.usb-audio")
    private var disconnectObserver: NSObjectProtocol?

    init?(uid: String) {
        guard let device = AVCaptureDevice(uniqueID: uid) else { return nil }
        self.device = device
        self.uid = uid
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
            device.activeFormat.formatDescription)?.pointee
        self.channelCount = Int(asbd?.mChannelsPerFrame ?? 0)
        super.init()
    }

    func start() throws {
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw StartError.cannotBuildSession
        }
        session.addInput(input)
        session.addOutput(output)
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil, queue: nil) { [weak self] note in
            guard let self, (note.object as? AVCaptureDevice) == self.device
            else { return }
            self.onDeviceGone?()
        }
        // startRunning blocks while the session spins up — never on main
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
            self.disconnectObserver = nil
        }
        queue.async { [session] in session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        onBuffer?(pcm, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// The delegate's CMSampleBuffer as an AVAudioPCMBuffer in the device's
    /// native format — the shape the converter downstream works in.
    private static func pcmBuffer(
        from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                description)?.pointee,
              let format = Self.format(for: &asbd)
        else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList) == noErr else { return nil }
        return pcm
    }

    /// AVAudioFormat for a raw stream description. Past two channels the
    /// plain initializer returns nil — a multichannel format needs a layout,
    /// and for a device's interleaved PCM the channels are positional, so
    /// discrete-in-order says exactly that.
    private static func format(
        for asbd: inout AudioStreamBasicDescription) -> AVAudioFormat? {
        let channels = asbd.mChannelsPerFrame
        guard channels > 2 else {
            return AVAudioFormat(streamDescription: &asbd)
        }
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        else { return nil }
        return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)
    }
}
