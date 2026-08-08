import AppKit
import CoreImage
import Foundation

/// How the phone finds the laptop: the addresses to type, and the code to
/// point a camera at.
enum RemoteAddress {
    /// One IPv4 address the machine answers on, with what `getifaddrs` said
    /// about the interface carrying it.
    ///
    /// A value type so the filtering below is a pure function: the rules for
    /// "which of these would a phone on the set network actually reach" are
    /// the part worth testing, and they cannot be tested against whatever
    /// networks the machine running the suite happens to be on.
    struct Candidate: Equatable, Sendable {
        /// BSD interface name — `en0`, `utun3`, `bridge100`.
        let interface: String
        let address: String
        /// IFF_RUNNING: the link is actually up. An Ethernet port with no
        /// cable in it is UP but not RUNNING, and still carries the address
        /// it had when the cable came out.
        let isRunning: Bool
        /// IFF_POINTOPOINT: a tunnel. Its address is on a network with one
        /// other end, and that end is not the phone.
        let isPointToPoint: Bool

        init(interface: String, address: String, isRunning: Bool = true,
             isPointToPoint: Bool = false) {
            self.interface = interface
            self.address = address
            self.isRunning = isRunning
            self.isPointToPoint = isPointToPoint
        }
    }

    /// Interface-name prefixes that are never a set network.
    ///
    /// The list is names rather than address ranges because the addresses are
    /// indistinguishable: a Docker bridge and a video-village router both hand
    /// out 192.168.x, and only the interface says which is which.
    ///
    /// - `lo` loopback: 127.0.0.1 on the phone is the phone.
    /// - `utun`, `ipsec`, `ppp`, `tun`, `tap`, `gif`, `stf`: VPN and tunnel
    ///   interfaces. macOS keeps a couple of `utun`s up at all times for
    ///   Handoff and Back to My Mac even with no VPN configured.
    /// - `awdl`, `llw`: Apple Wireless Direct Link and its low-latency
    ///   sibling — AirDrop's radio, not a network anything can be typed into.
    /// - `anpi`, `ap`: the internal management links on Apple silicon.
    /// - `bridge`: Internet Sharing and the Thunderbolt bridge.
    /// - `vmnet`, `vnic`, `vboxnet`, `vmenet`, `docker`: VMware, Parallels,
    ///   VirtualBox, the macOS virtualisation framework, Docker.
    static let virtualInterfacePrefixes = [
        "lo", "utun", "ipsec", "ppp", "tun", "tap", "gif", "stf",
        "awdl", "llw", "anpi", "ap", "bridge",
        "vmnet", "vnic", "vboxnet", "vmenet", "docker",
    ]

    /// Every IPv4 address the machine answers on, worth offering, best first.
    ///
    /// `getifaddrs` rather than anything higher level: on set the laptop is
    /// usually on two networks at once (the venue's Wi-Fi and a router shared
    /// with the video village), and the operator has to be able to read out
    /// whichever one the phones are on.
    static func ipv4Addresses() -> [String] {
        reachableAddresses(from: candidates())
    }

    /// What `getifaddrs` reports, unfiltered bar the IPv4 test.
    static func candidates() -> [Candidate] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [Candidate] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(address, socklen_t(address.pointee.sa_len),
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }
            // Through the pointer rather than the array: Swift 6 deprecates the
            // array overload of `String(cString:)`, and `getnameinfo` wrote a
            // terminated string into a buffer NI_MAXHOST long.
            guard let dotted = host.withUnsafeBufferPointer({
                $0.baseAddress.map { String(cString: $0) }
            }) else { continue }
            found.append(Candidate(
                interface: String(cString: pointer.pointee.ifa_name),
                address: dotted,
                isRunning: flags & IFF_RUNNING != 0,
                isPointToPoint: flags & IFF_POINTOPOINT != 0))
        }
        return found
    }

    /// The addresses worth showing, in the order they should be tried.
    ///
    /// A Mac on set is on more networks than it looks: the Wi-Fi, whatever is
    /// on the Thunderbolt dock, a couple of `utun`s macOS keeps up for its own
    /// services, and — on a machine that also does post — a Docker or Parallels
    /// bridge. Listing all of them makes the operator read six addresses down a
    /// phone screen to find the one that answers.
    ///
    /// What survives, and why:
    ///
    /// 1. **Loopback and link-local go.** 127.0.0.1 on the phone is the phone;
    ///    a self-assigned 169.254 address means DHCP never answered, so there
    ///    is no network there to reach the Mac on.
    /// 2. **Tunnels and virtual interfaces go** — see
    ///    `virtualInterfacePrefixes`, and the point-to-point flag for a tunnel
    ///    whose name is not on that list.
    /// 3. **An interface that is not RUNNING goes**: an Ethernet port keeps its
    ///    address after the cable is pulled, and that address answers nothing.
    ///
    /// What is left is ordered so the first line is the one to read out:
    /// physical `en*` interfaces first (Wi-Fi is `en0` on every portable Mac,
    /// and the phone is on Wi-Fi), private RFC 1918 addresses ahead of anything
    /// routable (a set network is private, always), then by interface number so
    /// the built-in radio precedes a dock's Ethernet.
    static func reachableAddresses(from candidates: [Candidate]) -> [String] {
        var seen: Set<String> = []
        return candidates
            .filter { isReachable($0) }
            .sorted { rank($0) < rank($1) }
            .compactMap { seen.insert($0.address).inserted ? $0.address : nil }
    }

    private static func isReachable(_ candidate: Candidate) -> Bool {
        guard candidate.isRunning, !candidate.isPointToPoint else { return false }
        guard !candidate.address.hasPrefix("127."),
              !candidate.address.hasPrefix("169.254."),
              candidate.address != "0.0.0.0" else { return false }
        return !virtualInterfacePrefixes.contains {
            candidate.interface.hasPrefix($0)
        }
    }

    /// Sort key: physical before everything else, private before routable,
    /// then the interface's number, then the address so equal ranks keep a
    /// stable order. Fields in the priority order stated in
    /// `reachableAddresses`, and `Comparable` reads them left to right.
    private struct Rank: Comparable {
        /// 0 for a physical `en*` interface, 1 for anything else.
        let physical: Int
        /// 0 for RFC 1918, 1 for a routable address.
        let private1918: Int
        /// The interface's number — `en0` before `en7`.
        let number: Int
        let address: String

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            (lhs.physical, lhs.private1918, lhs.number, lhs.address)
                < (rhs.physical, rhs.private1918, rhs.number, rhs.address)
        }
    }

    private static func rank(_ candidate: Candidate) -> Rank {
        Rank(physical: candidate.interface.hasPrefix("en") ? 0 : 1,
             private1918: isPrivate(candidate.address) ? 0 : 1,
             number: Int(candidate.interface.drop { !$0.isNumber }) ?? 999,
             address: candidate.address)
    }

    /// RFC 1918 space. Not a security test — it is the answer to "does this
    /// address belong to a network somebody could have plugged a phone into",
    /// and on set the answer is 10/8, 172.16/12 or 192.168/16 every time.
    static func isPrivate(_ address: String) -> Bool {
        if address.hasPrefix("10.") || address.hasPrefix("192.168.") {
            return true
        }
        let parts = address.split(separator: ".")
        guard parts.count == 4, parts[0] == "172",
              let second = Int(parts[1]) else { return false }
        return (16...31).contains(second)
    }

    /// The URLs to show in Settings for one page, in the order they should be
    /// tried.
    static func urls(port: Int, path: String = "/") -> [String] {
        ipv4Addresses().map { joined(host: "http://\($0):\(port)", path: path) }
    }

    /// Host and path with exactly one slash between them.
    ///
    /// Stated once because it was not: the host string carried a trailing
    /// slash and every page path starts with one, so `/script` and `/cameras`
    /// came out of Settings — and off the QR code — as `http://host:port//script`.
    /// A double slash is a different path to every router and proxy on the way,
    /// and this server answers 404 on it.
    static func joined(host: String, path: String) -> String {
        let base = host.hasSuffix("/") ? String(host.dropLast()) : host
        guard path != "/", !path.isEmpty else { return base + "/" }
        return base + (path.hasPrefix("/") ? path : "/" + path)
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
