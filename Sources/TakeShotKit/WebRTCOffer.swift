import Foundation

/// The browser's offer, read for the four things the app has to decide.
///
/// **Why the app parses an offer at all, when libdatachannel writes the
/// answer.** The library owns everything about the answer that is about the
/// TRANSPORT — the ICE credentials, the host candidates, the DTLS fingerprint,
/// the bundle group — and none of that is this app's business. What it cannot
/// know is what the picture is: which of the browser's dynamic payload types is
/// the H.264 this encoder actually produces, which media section that codec was
/// offered in, and whether the browser asked to receive at all. Those come out
/// of the offer, and they are exactly the fields `rtcAddTrackEx` takes.
///
/// So this file is the app's half of the answer, and it is pure Foundation —
/// which is what makes it the one half a headless suite can check against a
/// real captured offer (`WebRTCOfferTests`). The SDP the library then writes is
/// not covered by any test here and cannot be; see the report at the top of
/// `WebRTCViewer`.
///
/// **`packetization-mode=1` is a requirement and not a preference.** Mode 0
/// permits single NAL unit packets only — no FU-A — so a picture whose slices
/// exceed the MTU cannot be sent at all, and at 1080p every keyframe does. A
/// payload type offered without it is skipped rather than answered, because a
/// stream that negotiates mode 0 and then fragments is a black rectangle with
/// no error anywhere.
enum WebRTCOffer {
    /// What the app answers the browser's video section with.
    struct VideoPlan: Equatable, Sendable {
        /// The media identifier the offer gave that section. The answer's
        /// section has to carry the SAME one — it is how the two descriptions
        /// are lined up, and an answer whose mid does not match is an answer to
        /// a question nobody asked.
        var mid: String
        /// The payload type the OFFER numbered H.264 with. Never a constant of
        /// ours: the numbers are dynamic (96-127) and browsers assign them in
        /// whatever order their own codec list came out in, so the answerer
        /// uses the offerer's.
        var payloadType: UInt8
        /// The `a=fmtp` parameters, echoed back as they arrived.
        ///
        /// Echoed rather than composed: the answer's job here is to accept one
        /// of the configurations the offer put on the table, and re-deriving
        /// the string is a way to accept a slightly different one by accident.
        var formatParameters: String
    }

    /// H.264's rtpmap encoding name, as every browser spells it.
    static let codecName = "H264"

    /// The fmtp parameter that says FU-A is allowed. See the type comment.
    static let requiredPacketizationMode = "packetization-mode=1"

    /// `profile_idc` values, best first — the order the encoder's own output
    /// makes preferable.
    ///
    /// `SRTVideoEncoder` asks VideoToolbox for H.264 **High**, so a session that
    /// negotiated High is the one whose SDP describes what is actually on the
    /// wire. The two below it are what a browser offers when it does not lead
    /// with High, and they are answered rather than refused: H.264 decoders
    /// accept a higher profile than they advertised far more reliably than a
    /// director accepts a black rectangle, and the alternative — a second
    /// encoder session at Baseline — is the cost this whole design exists to
    /// avoid.
    static let profilePreference: [UInt8] = [
        0x64, // High
        0x4D, // Main
        0x42, // Constrained Baseline / Baseline
    ]

    /// The plan for `sdp`, or nil when there is nothing here to answer.
    ///
    /// nil covers every refusal in one value on purpose: an offer that is not
    /// SDP, an offer with no video, an offer whose video the browser will not
    /// receive, and an offer whose H.264 cannot be fragmented are four
    /// different mistakes with one correct response — refuse, and do not build
    /// a peer connection for it. The route answers 400 and the page says so.
    static func videoPlan(in sdp: String) -> VideoPlan? {
        guard let section = videoSection(in: sdp), section.wantsToReceive,
              let mid = section.mid else { return nil }
        guard let choice = section.h264.filter({
            $0.parameters.contains(requiredPacketizationMode)
        }).min(by: { left, right in
            let leftRank = rank(of: left.parameters)
            let rightRank = rank(of: right.parameters)
            return leftRank == rightRank
                ? left.payloadType < right.payloadType : leftRank < rightRank
        }) else { return nil }
        return VideoPlan(mid: mid, payloadType: choice.payloadType,
                         formatParameters: choice.parameters)
    }

    /// Where a payload type's `profile-level-id` sits in `profilePreference`;
    /// past the end when it names none of them, so an unknown profile sorts
    /// last rather than first.
    static func rank(of parameters: String) -> Int {
        guard let idc = profileIDC(in: parameters),
              let index = profilePreference.firstIndex(of: idc)
        else { return profilePreference.count }
        return index
    }

    /// The `profile_idc` byte out of a `profile-level-id`, which is three bytes
    /// of hex: profile, constraint flags, level. nil when the parameter is
    /// absent or is not six hex digits — an offer is a stranger's text and a
    /// half-parsed profile is worse than none.
    static func profileIDC(in parameters: String) -> UInt8? {
        for pair in parameters.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces)
                      == "profile-level-id" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.count == 6 else { return nil }
            return UInt8(value.prefix(2), radix: 16)
        }
        return nil
    }

    // MARK: - the walk

    /// One payload type as the offer described it.
    struct Codec: Equatable, Sendable {
        var payloadType: UInt8
        var parameters: String
    }

    /// The offer's first video media section, reduced to what matters here.
    struct VideoSection: Equatable, Sendable {
        var mid: String?
        var h264: [Codec] = []
        /// The browser asked to RECEIVE this section, which is the only shape
        /// this app answers: it sends a picture and takes nothing back.
        /// `sendrecv` is the SDP default when no direction attribute is
        /// present, which is why the absence is a yes.
        var wantsToReceive = true
    }

    /// Read the first `m=video` section. Everything before it and every section
    /// after it is skipped: audio and data channels are not this task's, and a
    /// second video section is a camera this seam does not carry yet.
    static func videoSection(in sdp: String) -> VideoSection? {
        var section: VideoSection?
        var names: [UInt8: String] = [:]
        var parameters: [UInt8: String] = [:]
        for line in sdp.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("m=") {
                if section != nil { break }
                guard text.hasPrefix("m=video ") else { continue }
                section = VideoSection()
                continue
            }
            guard section != nil, text.hasPrefix("a=") else { continue }
            let attribute = String(text.dropFirst(2))
            if let value = suffix(of: attribute, after: "mid:") {
                section?.mid = value
            } else if let value = suffix(of: attribute, after: "rtpmap:"),
                      let (payloadType, rest) = split(value) {
                names[payloadType] = rest
            } else if let value = suffix(of: attribute, after: "fmtp:"),
                      let (payloadType, rest) = split(value) {
                parameters[payloadType] = rest
            } else if attribute == "sendonly" || attribute == "inactive" {
                section?.wantsToReceive = false
            }
        }
        guard var found = section else { return nil }
        found.h264 = names.filter {
            $0.value.uppercased().hasPrefix(codecName + "/")
        }.keys.sorted().map {
            Codec(payloadType: $0, parameters: parameters[$0] ?? "")
        }
        return found
    }

    /// `"mid:0"` past `"mid:"`, or nil when the attribute is a different one.
    private static func suffix(of attribute: String,
                               after name: String) -> String? {
        guard attribute.hasPrefix(name) else { return nil }
        return String(attribute.dropFirst(name.count))
            .trimmingCharacters(in: .whitespaces)
    }

    /// `"102 H264/90000"` as (102, "H264/90000"). nil when the number is not
    /// one, which is how a line this app does not understand stays out of the
    /// tables above.
    private static func split(_ value: String) -> (UInt8, String)? {
        let parts = value.split(separator: " ", maxSplits: 1)
        guard let first = parts.first, let payloadType = UInt8(first)
        else { return nil }
        return (payloadType, parts.count > 1 ? String(parts[1]) : "")
    }
}
