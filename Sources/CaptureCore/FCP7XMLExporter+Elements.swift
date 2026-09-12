import Foundation

/// The elements of the `xmeml` document — everything that turns a `Placed`
/// into text. Split from the arithmetic next door so neither file has to be
/// read to change the other.
extension FCP7XMLExporter {
    /// A rate, which `xmeml` states the same way everywhere it appears.
    static func rateElement(_ rate: Rate, indent: String) -> String {
        """
        \(indent)<rate>
        \(indent)  <timebase>\(rate.timebase)</timebase>
        \(indent)  <ntsc>\(rate.ntsc ? "TRUE" : "FALSE")</ntsc>
        \(indent)</rate>
        """
    }

    /// A timecode block: the rate it is numbered on, the human string, the
    /// frame ordinal behind it, and which of the two numbering schemes it is.
    ///
    /// Both the string and the frame, because readers disagree about which one
    /// they trust — and they cannot disagree with each other here, since the
    /// ordinal is the one `Timecode` derived the string from.
    static func timecodeElement(_ timecode: Timecode?, rate: Rate,
                                indent: String) -> String {
        let value = timecode ?? Timecode(frameNumber: 0, fps: rate.timebase)
        return """
        \(indent)<timecode>
        \(rateElement(rate, indent: indent + "  "))
        \(indent)  <string>\(value.description)</string>
        \(indent)  <frame>\(value.frameNumber)</frame>
        \(indent)  <displayformat>\(value.isDropFrame ? "DF" : "NDF")\
        </displayformat>
        \(indent)</timecode>
        """
    }

    /// The file, stated in full — every later reference is `<file id="…"/>`,
    /// which is what the format expects and what keeps a day of takes from
    /// repeating its own paths twice over.
    ///
    /// `<channelcount>` is deliberately absent: a take carries no audio
    /// description, so a number here would be invented — the same fact
    /// `FCPXMLExporter` refuses to invent on its asset. The sound clip below
    /// names track 1, which is the one track `TakeWriter` writes whatever its
    /// channel width, so nothing has to know how wide it is.
    static func fileElement(_ clip: Placed, indent: String) -> String {
        """
        \(indent)<file id="\(clip.fileID)">
        \(indent)  <name>\(escape(clip.take.url.lastPathComponent))</name>
        \(indent)  <pathurl>\(escape(clip.take.url.absoluteString))</pathurl>
        \(rateElement(clip.rate, indent: indent + "  "))
        \(indent)  <duration>\(clip.frames)</duration>
        \(timecodeElement(clip.take.startTimecode, rate: clip.rate,
                          indent: indent + "  "))
        \(indent)  <media>
        \(indent)    <video>
        \(indent)      <samplecharacteristics>
        \(rateElement(clip.rate, indent: indent + "        "))
        \(indent)        <width>\(clip.width)</width>
        \(indent)        <height>\(clip.height)</height>
        \(indent)      </samplecharacteristics>
        \(indent)    </video>
        \(indent)    <audio/>
        \(indent)  </media>
        \(indent)</file>
        """
    }

    /// The picture clip: where it sits on the timeline, what part of the file
    /// it shows, the file itself, its markers and its link to the sound.
    ///
    /// `in` is 0 and `out` is the whole file. A take IS the clip — the in/out
    /// an operator marks during review is a loop range for watching, and a
    /// timeline that quietly dropped the footage outside it would be an export
    /// nobody asked for. The shift report is where that mark is stated.
    static func videoClip(_ clip: Placed) -> String {
        let body = """
                  <clipitem id="\(clip.videoID)">
                    <name>\(escape(clip.take.displayName))</name>
                    <duration>\(clip.frames)</duration>
        \(rateElement(clip.rate, indent: "            "))
                    <start>\(clip.offset)</start>
                    <end>\(clip.offset + clip.recordFrames)</end>
                    <in>0</in>
                    <out>\(clip.frames)</out>
        \(fileElement(clip, indent: "            "))
                    <sourcetrack>
                      <mediatype>video</mediatype>
                      <trackindex>1</trackindex>
                    </sourcetrack>
        """
        return [body, markerElements(clip), linkElements(clip),
                "          </clipitem>"]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The sound clip: the same file, the same positions, track 1 of its
    /// media. `<file id="…"/>` alone — the picture clip above stated it.
    static func audioClip(_ clip: Placed) -> String {
        let body = """
                  <clipitem id="\(clip.audioID)">
                    <name>\(escape(clip.take.displayName))</name>
                    <duration>\(clip.frames)</duration>
        \(rateElement(clip.rate, indent: "            "))
                    <start>\(clip.offset)</start>
                    <end>\(clip.offset + clip.recordFrames)</end>
                    <in>0</in>
                    <out>\(clip.frames)</out>
                    <file id="\(clip.fileID)"/>
                    <sourcetrack>
                      <mediatype>audio</mediatype>
                      <trackindex>1</trackindex>
                    </sourcetrack>
        """
        return [body, linkElements(clip), "          </clipitem>"]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The markers flagged during the take, on the CLIP's own media.
    ///
    /// `in` counts from frame 0 of the FILE, not from the take's timecode:
    /// this format places a clip marker against the media, and a position
    /// measured from the start timecode would land it ten hours past the end.
    /// (The FCPXML writer next door does the opposite for the opposite reason
    /// — its clip timeline starts at the asset's source timecode.)
    ///
    /// `out` is -1, which is this format's "a point, not a range".
    static func markerElements(_ clip: Placed) -> String {
        clip.take.markers.map { marker in
            let name = marker.note.isEmpty ? marker.timecodeText : marker.note
            let at = TakeLogExporter.frameOffset(seconds: marker.seconds,
                                                 for: clip.take)
            return """
                        <marker>
                          <name>\(escape(name))</name>
                          <comment></comment>
                          <in>\(at)</in>
                          <out>-1</out>
                        </marker>
            """
        }.joined(separator: "\n")
    }

    /// What joins the picture and the sound into one clip an editor can trim.
    ///
    /// Both members of the pair carry the WHOLE group — that is the format's
    /// shape, not a duplication: a reader resolving a link from either side
    /// finds the other without having to have read it yet.
    static func linkElements(_ clip: Placed) -> String {
        """
                    <link>
                      <linkclipref>\(clip.videoID)</linkclipref>
                      <mediatype>video</mediatype>
                      <trackindex>1</trackindex>
                      <clipindex>\(clip.index)</clipindex>
                    </link>
                    <link>
                      <linkclipref>\(clip.audioID)</linkclipref>
                      <mediatype>audio</mediatype>
                      <trackindex>1</trackindex>
                      <clipindex>\(clip.index)</clipindex>
                      <groupindex>1</groupindex>
                    </link>
        """
    }

    /// The document around one or more sequences.
    ///
    /// `xmeml` takes several `<sequence>` children, which is how a project
    /// spanning nights arrives as several timelines in one import rather than
    /// as three days laid end to end as if they were one (owner: "может нам
    /// учитывать многосменность в экспорте хмл").
    ///
    /// No `<uuid>`: the element is optional, and the only value this could put
    /// there is a fresh one per export — which would make two exports of one
    /// unchanged day differ, for a DIT syncing the folder and for the suite
    /// that reads this back.
    static func document(_ sequences: [String]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="5">
        \(sequences.joined(separator: "\n"))
        </xmeml>

        """
    }

    /// One shift as one sequence.
    static func sequenceElement(_ head: Head, video: [String],
                                audio: [String]) -> String {
        """
          <sequence id="\(head.id)">
            <name>\(head.name)</name>
            <duration>\(head.duration)</duration>
        \(rateElement(head.rate, indent: "    "))
        \(timecodeElement(Timecode(frameNumber: 0, fps: head.rate.timebase),
                          rate: head.rate, indent: "    "))
            <media>
              <video>
                <format>
                  <samplecharacteristics>
        \(rateElement(head.rate, indent: "            "))
                    <width>\(head.width)</width>
                    <height>\(head.height)</height>
                    <pixelaspectratio>square</pixelaspectratio>
                  </samplecharacteristics>
                </format>
                <track>
        \(video.joined(separator: "\n"))
                </track>
              </video>
              <audio>
                <track>
        \(audio.joined(separator: "\n"))
                </track>
              </audio>
            </media>
          </sequence>
        """
    }
}
