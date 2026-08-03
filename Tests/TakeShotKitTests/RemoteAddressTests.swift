import Foundation
import Testing

@testable import TakeShotKit

/// What Settings reads out: which of the machine's addresses are worth
/// offering, in what order, and the URL each page is reached at.
///
/// The filtering is tested against a synthetic interface list rather than
/// against `getifaddrs`. A suite that asked the machine what networks it is on
/// would assert something different on every runner — and would pass on a
/// laptop with one Wi-Fi connection while the failures it exists to catch all
/// need a VPN, a Docker install or a dock plugged in.
@Suite struct RemoteAddressTests {
    private typealias Candidate = RemoteAddress.Candidate

    // MARK: - the URLs (owner item 10)

    /// The bug this file was opened for: the host carried a trailing slash and
    /// every page path starts with one, so Settings offered — and the QR code
    /// encoded — `http://host:port//script`. The server answers 404 on that.
    @Test func noRouteComesOutWithADoubleSlash() {
        for link in RemoteLink.allCases {
            let url = RemoteAddress.joined(host: "http://192.168.1.5:8765",
                                           path: link.path)
            #expect(!url.dropFirst("http://".count).contains("//"),
                    "\(link.rawValue) built \(url)")
            #expect(url.hasPrefix("http://192.168.1.5:8765/"))
        }
        #expect(RemoteAddress.joined(host: "http://10.0.0.2:8765",
                                     path: RemoteLink.remote.path)
            == "http://10.0.0.2:8765/")
        #expect(RemoteAddress.joined(host: "http://10.0.0.2:8765",
                                     path: RemoteLink.script.path)
            == "http://10.0.0.2:8765/script")
        #expect(RemoteAddress.joined(host: "http://10.0.0.2:8765",
                                     path: RemoteLink.cameras.path)
            == "http://10.0.0.2:8765/cameras")
    }

    /// The join is defensive on both sides: a host that already ends in a
    /// slash and a path that forgot its leading one both produce one separator.
    @Test func theJoinIsIndifferentToWhoCarriesTheSlash() {
        #expect(RemoteAddress.joined(host: "http://h:1/", path: "/script")
            == "http://h:1/script")
        #expect(RemoteAddress.joined(host: "http://h:1", path: "script")
            == "http://h:1/script")
        #expect(RemoteAddress.joined(host: "http://h:1/", path: "/")
            == "http://h:1/")
        #expect(RemoteAddress.joined(host: "http://h:1", path: "")
            == "http://h:1/")
    }

    /// Each of the three pages is reachable as its own link, and no two of
    /// them share a path — the switch in Settings has three distinct targets
    /// or it is a switch that does nothing.
    @Test func theLinkSwitcherExposesEveryTarget() {
        let paths = RemoteLink.allCases.map(\.path)
        #expect(paths == ["/", "/script", "/cameras"])
        #expect(Set(paths).count == RemoteLink.allCases.count)
        #expect(RemoteLink.allCases.map(\.labelKey).allSatisfy { !$0.isEmpty })
        // The routes the server answers are these and not copies of them.
        #expect(RemotePage.scriptPath == RemoteLink.script.path)
        #expect(RemotePage.camerasPath == RemoteLink.cameras.path)
    }

    /// The whole-list call composes the same way, for every page.
    @Test func theSettingsListJoinsEveryAddressToThePage() {
        for link in RemoteLink.allCases {
            for url in RemoteAddress.urls(port: 8765, path: link.path) {
                #expect(!url.dropFirst("http://".count).contains("//"), "\(url)")
            }
        }
    }

    // MARK: - which interfaces survive (owner item 19)

    /// Loopback and a self-assigned link-local address are both dropped:
    /// 127.0.0.1 on the phone is the phone, and a 169.254 address means DHCP
    /// never answered, so there is no network there to be reached on.
    @Test func loopbackAndLinkLocalNeverReachTheOperator() {
        let found = RemoteAddress.reachableAddresses(from: [
            Candidate(interface: "lo0", address: "127.0.0.1"),
            Candidate(interface: "en0", address: "169.254.31.7"),
            Candidate(interface: "en1", address: "192.168.10.4"),
        ])
        #expect(found == ["192.168.10.4"])
    }

    /// The interfaces a machine that also does post is covered in: VPN
    /// tunnels, AirDrop's radio, the Docker and Parallels bridges. Every one
    /// of them carries a plausible-looking address and none of them is a
    /// network anybody can put a phone on.
    @Test func tunnelsAndVirtualBridgesAreDropped() {
        let found = RemoteAddress.reachableAddresses(from: [
            Candidate(interface: "utun4", address: "10.8.0.6",
                      isPointToPoint: true),
            Candidate(interface: "awdl0", address: "192.168.4.1"),
            Candidate(interface: "llw0", address: "192.168.4.2"),
            Candidate(interface: "bridge100", address: "192.168.64.1"),
            Candidate(interface: "vmnet8", address: "172.16.180.1"),
            Candidate(interface: "vnic0", address: "10.211.55.2"),
            Candidate(interface: "en0", address: "192.168.1.42"),
        ])
        #expect(found == ["192.168.1.42"])
    }

    /// A tunnel whose name is not on the list is still a tunnel: the
    /// point-to-point flag says so, and its far end is not the phone.
    @Test func aPointToPointInterfaceIsDroppedOnItsFlagAlone() {
        let found = RemoteAddress.reachableAddresses(from: [
            Candidate(interface: "ztq7", address: "10.147.20.9",
                      isPointToPoint: true),
            Candidate(interface: "en0", address: "192.168.1.42"),
        ])
        #expect(found == ["192.168.1.42"])
    }

    /// An Ethernet port keeps its address after the cable comes out — UP, but
    /// no longer RUNNING. Offering it sends the operator chasing a network
    /// that answers nothing.
    @Test func anInterfaceThatIsNotRunningIsDropped() {
        let found = RemoteAddress.reachableAddresses(from: [
            Candidate(interface: "en5", address: "192.168.9.3",
                      isRunning: false),
            Candidate(interface: "en0", address: "192.168.1.42"),
        ])
        #expect(found == ["192.168.1.42"])
    }

    /// The order is the point of the list: the first line is the one to read
    /// out. Wi-Fi is `en0` on every portable Mac and the phone is on Wi-Fi, so
    /// physical interfaces lead, lowest number first; a private address beats
    /// a routable one, because a set network is private every time.
    @Test func theAddressAPhoneWouldUseComesFirst() {
        let found = RemoteAddress.reachableAddresses(from: [
            Candidate(interface: "en7", address: "192.168.100.5"),
            Candidate(interface: "en0", address: "192.168.1.42"),
        ])
        #expect(found.first == "192.168.1.42", "the dock outranked the radio")

        let mixed = RemoteAddress.reachableAddresses(from: [
            Candidate(interface: "en0", address: "203.0.113.9"),
            Candidate(interface: "en3", address: "10.0.5.20"),
        ])
        #expect(mixed.first == "10.0.5.20",
                "a routable address was offered ahead of the set network")
    }

    /// Nothing is lost on the way: an address that survives the filter is
    /// still offered even when it is not the best one, and duplicates
    /// (the same address on two aliases) are shown once.
    @Test func everySurvivingAddressIsListedOnce() {
        let found = RemoteAddress.reachableAddresses(from: [
            Candidate(interface: "en0", address: "192.168.1.42"),
            Candidate(interface: "en1", address: "10.0.5.20"),
            Candidate(interface: "en1", address: "192.168.1.42"),
        ])
        #expect(found == ["192.168.1.42", "10.0.5.20"])
    }

    @Test func theRFC1918TestCoversTheRangesASetNetworkUses() {
        for address in ["10.0.0.1", "192.168.1.1", "172.16.0.1", "172.31.255.4"] {
            #expect(RemoteAddress.isPrivate(address), "\(address)")
        }
        for address in ["172.15.0.1", "172.32.0.1", "203.0.113.9", "8.8.8.8"] {
            #expect(!RemoteAddress.isPrivate(address), "\(address)")
        }
    }

    /// Whatever the machine running the suite is plugged into, the live call
    /// may not hand back a loopback, a link-local or a tunnel.
    @Test func theLiveListObeysItsOwnRules() {
        for address in RemoteAddress.ipv4Addresses() {
            #expect(!address.hasPrefix("127."), "\(address)")
            #expect(!address.hasPrefix("169.254."), "\(address)")
        }
    }
}
