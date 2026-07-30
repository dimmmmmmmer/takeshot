import AppKit
import CoreImage
import Foundation

/// How the phone finds the laptop: the addresses to type, and the code to
/// point a camera at.
enum RemoteAddress {
    /// Every IPv4 address the machine answers on, loopback excluded.
    ///
    /// `getifaddrs` rather than anything higher level: on set the laptop is
    /// usually on two networks at once (the venue's Wi-Fi and a router shared
    /// with the video village), and the operator has to be able to read out
    /// whichever one the phones are on. Loopback is dropped because 127.0.0.1
    /// on the phone is the phone.
    static func ipv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(address, socklen_t(address.pointee.sa_len),
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }
            let text = String(cString: host)
            // A self-assigned 169.254 address means DHCP never answered: the
            // phone will not reach it, so offering it as the address to type
            // sends the operator chasing a network that is not there.
            guard !text.hasPrefix("169.254."), !found.contains(text) else { continue }
            found.append(text)
        }
        return found
    }

    /// The URLs to show in Settings, in the order they should be tried.
    static func urls(port: Int) -> [String] {
        ipv4Addresses().map { "http://\($0):\(port)/" }
    }

    /// A QR code for `text`, rendered at `side` points.
    ///
    /// Deliberately encodes the URL alone, never the PIN. A code on a laptop
    /// screen is photographed by whoever walks past it; the four digits beside
    /// it are read out to the people who are meant to have them. Splitting the
    /// two is the entire point of having a PIN.
    static func qrImage(for text: String, side: CGFloat = 132) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        // "M" recovers from a fingerprint on the screen without making the
        // modules so small that a phone camera has to be held still.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = side / max(1, output.extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale,
                                                              y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent)
        else { return nil }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: side, height: side))
    }
}
