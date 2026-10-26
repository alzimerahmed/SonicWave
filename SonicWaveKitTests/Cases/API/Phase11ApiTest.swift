//
//  Phase11ApiTest.swift
//  SonicWaveKitTests
//
//  Created by Alzimer Ahmed on 27.02.26.
//  Copyright (c) 2026 Alzimer Ahmed. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

@testable import SonicWaveKit
import XCTest

/// Phase-11A units (G11 jukebox + UPnP, G19 bookmarks, G23 music-folder
/// filter, G25 Lidarr): request-URL construction, response parsers and
/// wire-format builders — all static/delegate seams, no network.
class Phase11ApiTest: XCTestCase {
  private func items(
    _ urlComp: URLComponents,
    named name: String
  ) -> [String] {
    urlComp.queryItems?.filter { $0.name == name }.compactMap { $0.value } ?? []
  }

  // MARK: G11 Subsonic jukeboxControl query building

  private func jukeboxComp(action: JukeboxAction) -> URLComponents {
    var urlComp = URLComponents(string: "https://test.local/rest/jukeboxControl.view")!
    SubsonicServerApi.appendJukeboxQueryItems(to: &urlComp, action: action)
    return urlComp
  }

  func testJukeboxGetStartStopClear() {
    XCTAssertEqual(items(jukeboxComp(action: .get), named: "action"), ["get"])
    XCTAssertEqual(items(jukeboxComp(action: .start), named: "action"), ["start"])
    XCTAssertEqual(items(jukeboxComp(action: .stop), named: "action"), ["stop"])
    XCTAssertEqual(items(jukeboxComp(action: .clear), named: "action"), ["clear"])
  }

  func testJukeboxSkipCarriesIndexAndOffset() {
    let comp = jukeboxComp(action: .skip(index: 3, offsetSeconds: 42))
    XCTAssertEqual(items(comp, named: "action"), ["skip"])
    XCTAssertEqual(items(comp, named: "index"), ["3"])
    XCTAssertEqual(items(comp, named: "offset"), ["42"])
  }

  func testJukeboxAddRepeatsIdInOrder() {
    let comp = jukeboxComp(action: .add(ids: ["a", "b", "c"]))
    XCTAssertEqual(items(comp, named: "action"), ["add"])
    XCTAssertEqual(items(comp, named: "id"), ["a", "b", "c"])
  }

  func testJukeboxSetAndSetGain() {
    let set = jukeboxComp(action: .set(index: 7))
    XCTAssertEqual(items(set, named: "action"), ["set"])
    XCTAssertEqual(items(set, named: "index"), ["7"])
    let gain = jukeboxComp(action: .setGain(0.5))
    XCTAssertEqual(items(gain, named: "action"), ["setGain"])
    XCTAssertEqual(items(gain, named: "gain"), ["0.5"])
  }

  // MARK: G11 Ampache localplay query building

  private func localplayComp(
    command: String,
    oid: String? = nil,
    type: String? = nil,
    clear: Bool? = nil
  ) -> URLComponents {
    var urlComp = URLComponents(string: "https://test.local/server/xml.server.php")!
    AmpacheXmlServerApi.appendLocalplayQueryItems(
      to: &urlComp,
      command: command,
      objectId: oid,
      objectType: type,
      clear: clear
    )
    return urlComp
  }

  func testLocalplayCommandAndOptionals() {
    let comp = localplayComp(command: "add", oid: "42", type: "song")
    XCTAssertEqual(items(comp, named: "action"), ["localplay"])
    XCTAssertEqual(items(comp, named: "command"), ["add"])
    XCTAssertEqual(items(comp, named: "oid"), ["42"])
    XCTAssertEqual(items(comp, named: "type"), ["song"])
    XCTAssertTrue(items(comp, named: "clear").isEmpty)
  }

  func testLocalplayClearFlag() {
    let comp = localplayComp(command: "delete_all", clear: true)
    XCTAssertEqual(items(comp, named: "clear"), ["1"])
  }

  // MARK: G11 Subsonic jukeboxStatus parsing

  func testSsJukeboxParserStatus() {
    let xml = """
      <?xml version="1.0"?>
      <subsonic-response xmlns="http://subsonic.org/restapi" status="ok" version="1.16.1">
        <jukeboxStatus currentIndex="1" playing="true" gain="0.5" position="12">
          <entry id="s1" title="Song A" artist="Artist A" album="Album A" duration="200"/>
          <entry id="s2" title="Song B" artist="Artist B" duration="180"/>
        </jukeboxStatus>
      </subsonic-response>
      """
    let delegate = SsJukeboxParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = delegate
    XCTAssertTrue(parser.parse())
    XCTAssertNil(delegate.error)
    let playlist = delegate.jukeboxPlaylist
    XCTAssertNotNil(playlist)
    XCTAssertEqual(playlist?.currentIndex, 1)
    XCTAssertEqual(playlist?.isPlaying, true)
    XCTAssertEqual(playlist?.gain, 0.5)
    XCTAssertEqual(playlist?.positionSeconds, 12)
    XCTAssertEqual(playlist?.entries.count, 2)
    XCTAssertEqual(playlist?.entries.first?.id, "s1")
    XCTAssertEqual(playlist?.entries.first?.title, "Song A")
    XCTAssertEqual(playlist?.entries.first?.artistName, "Artist A")
    XCTAssertEqual(playlist?.entries.first?.durationSeconds, 200)
  }

  func testSsJukeboxParserError() {
    let xml = """
      <?xml version="1.0"?>
      <subsonic-response status="failed" version="1.16.1">
        <error code="50" message="User not authorized for jukebox"/>
      </subsonic-response>
      """
    let delegate = SsJukeboxParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = delegate
    parser.parse()
    XCTAssertEqual(delegate.error?.statusCode, 50)
    XCTAssertNil(delegate.jukeboxPlaylist)
  }

  // MARK: G19 Subsonic bookmarks parsing (position ms -> s)

  func testSsBookmarksParser() {
    let xml = """
      <?xml version="1.0"?>
      <subsonic-response xmlns="http://subsonic.org/restapi" status="ok" version="1.16.1">
        <bookmarks>
          <bookmark position="66000" username="u" comment="" created="2024-01-01T10:00:00.000Z" changed="2024-01-02T10:00:00.000Z">
            <entry id="song-1" title="Bookmarked Song" artist="Artist" album="Album" duration="300"/>
          </bookmark>
          <bookmark position="5000" username="u" created="2024-01-01T10:00:00.000Z">
            <entry id="ep-1" title="Episode" duration="3600"/>
          </bookmark>
        </bookmarks>
      </subsonic-response>
      """
    let delegate = SsBookmarksParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = delegate
    XCTAssertTrue(parser.parse())
    XCTAssertNil(delegate.error)
    XCTAssertEqual(delegate.bookmarks.count, 2)
    let first = delegate.bookmarks[0]
    XCTAssertEqual(first.id, "song-1")
    // milliseconds are converted to seconds
    XCTAssertEqual(first.positionSeconds, 66)
    XCTAssertEqual(first.username, "u")
    XCTAssertEqual(first.entry?.title, "Bookmarked Song")
    XCTAssertEqual(first.entry?.artistName, "Artist")
    XCTAssertEqual(first.entry?.durationSeconds, 300)
    XCTAssertNotNil(first.created)
    XCTAssertNotNil(first.changed)
    let second = delegate.bookmarks[1]
    XCTAssertEqual(second.id, "ep-1")
    XCTAssertEqual(second.positionSeconds, 5)
  }

  // MARK: G19 Ampache bookmarks parsing (position already seconds)

  func testAmpacheBookmarksParser() {
    let xml = """
      <?xml version="1.0"?>
      <root>
        <bookmark id="3">
          <user>tester</user>
          <object_type>song</object_type>
          <object_id>115</object_id>
          <position>10</position>
          <client>SonicWave</client>
          <creation_date>1700000000</creation_date>
          <update_date>1700000100</update_date>
        </bookmark>
        <bookmark id="4">
          <object_type>podcast_episode</object_type>
          <object_id>88</object_id>
          <position>95</position>
        </bookmark>
      </root>
      """
    let delegate = AmpacheBookmarksParserDelegate(
      performanceMonitor: MOCK_PerformanceMonitor()
    )
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = delegate
    XCTAssertTrue(parser.parse())
    XCTAssertNil(delegate.error)
    XCTAssertEqual(delegate.bookmarks.count, 2)
    let first = delegate.bookmarks[0]
    XCTAssertEqual(first.id, "115")
    XCTAssertEqual(first.objectType, "song")
    XCTAssertEqual(first.positionSeconds, 10)
    XCTAssertEqual(first.username, "tester")
    XCTAssertEqual(first.clientName, "SonicWave")
    XCTAssertNotNil(first.created)
    XCTAssertEqual(first.changed, Date(timeIntervalSince1970: 1_700_000_100))
    let second = delegate.bookmarks[1]
    XCTAssertEqual(second.objectType, "podcast_episode")
    XCTAssertEqual(second.positionSeconds, 95)
  }

  // MARK: G11 Ampache localplay_songs parsing

  func testAmpacheLocalplaySongsParser() {
    let xml = """
      <?xml version="1.0"?>
      <root>
        <song id="11">
          <title>Local Song</title>
          <name>Local Song</name>
          <artist id="7"><name>The Artist</name></artist>
          <album id="9"><name>The Album</name></album>
          <time>240</time>
        </song>
      </root>
      """
    let delegate = AmpacheLocalplaySongsParserDelegate(
      performanceMonitor: MOCK_PerformanceMonitor()
    )
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = delegate
    XCTAssertTrue(parser.parse())
    XCTAssertNil(delegate.error)
    XCTAssertEqual(delegate.entries.count, 1)
    let entry = delegate.entries[0]
    XCTAssertEqual(entry.id, "11")
    XCTAssertEqual(entry.title, "Local Song")
    XCTAssertEqual(entry.artistName, "The Artist")
    XCTAssertEqual(entry.albumName, "The Album")
    XCTAssertEqual(entry.durationSeconds, 240)
  }

  // MARK: G23 musicFolderId propagation + folder list parsing

  func testMusicFolderQueryItemAppendedOnlyWhenSet() {
    var withFolder = URLComponents(string: "https://test.local/rest/getArtists.view")!
    SubsonicServerApi.appendMusicFolderQueryItems(to: &withFolder, musicFolderId: "folder-9")
    XCTAssertEqual(items(withFolder, named: "musicFolderId"), ["folder-9"])

    var empty = URLComponents(string: "https://test.local/rest/getArtists.view")!
    SubsonicServerApi.appendMusicFolderQueryItems(to: &empty, musicFolderId: "")
    XCTAssertTrue(items(empty, named: "musicFolderId").isEmpty)

    var nilFolder = URLComponents(string: "https://test.local/rest/getArtists.view")!
    SubsonicServerApi.appendMusicFolderQueryItems(to: &nilFolder, musicFolderId: nil)
    XCTAssertTrue(items(nilFolder, named: "musicFolderId").isEmpty)
  }

  func testSsMusicFolderListParser() {
    let xml = """
      <?xml version="1.0"?>
      <subsonic-response xmlns="http://subsonic.org/restapi" status="ok" version="1.16.1">
        <musicFolders>
          <musicFolder id="1" name="Music"/>
          <musicFolder id="2" name="Audiobooks"/>
        </musicFolders>
      </subsonic-response>
      """
    let delegate = SsMusicFolderListParserDelegate(
      performanceMonitor: MOCK_PerformanceMonitor()
    )
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = delegate
    XCTAssertTrue(parser.parse())
    XCTAssertNil(delegate.error)
    XCTAssertEqual(delegate.musicFolders.count, 2)
    XCTAssertEqual(delegate.musicFolders[0].id, "1")
    XCTAssertEqual(delegate.musicFolders[0].name, "Music")
    XCTAssertEqual(delegate.musicFolders[1].name, "Audiobooks")
  }

  // MARK: G11 SSDP wire format

  func testSsdpMSearchRequest() {
    let request = SsdpMessages.mSearchRequest(
      searchTarget: "urn:schemas-upnp-org:service:AVTransport:1",
      maxWaitSeconds: 2
    )
    XCTAssertTrue(request.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
    XCTAssertTrue(request.contains("HOST: 239.255.255.250:1900\r\n"))
    XCTAssertTrue(request.contains("MAN: \"ssdp:discover\"\r\n"))
    XCTAssertTrue(request.contains("MX: 2\r\n"))
    XCTAssertTrue(request.contains("ST: urn:schemas-upnp-org:service:AVTransport:1\r\n"))
    XCTAssertTrue(request.hasSuffix("\r\n\r\n"))
  }

  func testSsdpResponseParsing() {
    let response = "HTTP/1.1 200 OK\r\n" +
      "LOCATION: http://192.168.1.10:1400/xml/device.xml\r\n" +
      "ST: urn:schemas-upnp-org:service:AVTransport:1\r\n" +
      "USN: uuid:RINCON_AAAA::urn:schemas-upnp-org:service:AVTransport:1\r\n" +
      "SERVER: Linux/4.4 UPnP/1.0 Sonos/60.1\r\n" +
      "\r\n"
    let parsed = SsdpMessages.parseResponse(response)
    XCTAssertEqual(parsed.location, "http://192.168.1.10:1400/xml/device.xml")
    XCTAssertEqual(parsed.st, "urn:schemas-upnp-org:service:AVTransport:1")
    // USN keeps only the uuid part before `::`
    XCTAssertEqual(parsed.usn, "uuid:RINCON_AAAA")
    XCTAssertEqual(parsed.server, "Linux/4.4 UPnP/1.0 Sonos/60.1")
  }

  func testSsdpResponseParsingToleratesCaseAndMissing() {
    let parsed = SsdpMessages.parseResponse("location: http://x/dev.xml\n\n")
    XCTAssertEqual(parsed.location, "http://x/dev.xml")
    XCTAssertNil(parsed.usn)
    XCTAssertNil(parsed.st)
  }

  // MARK: G11 UPnP SOAP wire format

  func testUpnpSoapEnvelope() {
    let body = UpnpSoap.actionBody(
      serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
      action: "Stop",
      arguments: [("InstanceID", "0")]
    )
    XCTAssertTrue(body.contains("<u:Stop xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
    XCTAssertTrue(body.contains("<InstanceID>0</InstanceID>"))
    XCTAssertTrue(body.contains("</u:Stop>"))
    XCTAssertEqual(
      UpnpSoap.soapActionHeader(
        serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
        action: "Play"
      ),
      "\"urn:schemas-upnp-org:service:AVTransport:1#Play\""
    )
  }

  func testUpnpSoapEscapesMetadata() {
    let metadata = UpnpSoap.avTransportUriMetadata(title: "A&B <Song>", creator: "Art\"ist")
    XCTAssertTrue(metadata.contains("<dc:title>A&amp;B &lt;Song&gt;</dc:title>"))
    XCTAssertTrue(metadata.contains("<dc:creator>Art&quot;ist</dc:creator>"))
    XCTAssertTrue(metadata.contains("object.item.audioItem.musicTrack"))
  }

  // MARK: G11 UPnP device description parsing

  func testUpnpDeviceDescriptionParser() {
    let xml = """
      <?xml version="1.0"?>
      <root xmlns="urn:schemas-upnp-org:device-1-0">
        <device>
          <friendlyName>Kitchen Speaker</friendlyName>
          <UDN>uuid:RINCON_AAAA</UDN>
          <serviceList>
            <service>
              <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
              <controlURL>/MediaRenderer/RenderingControl/Control</controlURL>
            </service>
            <service>
              <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
              <controlURL>/MediaRenderer/AVTransport/Control</controlURL>
            </service>
          </serviceList>
        </device>
      </root>
      """
    let delegate = UpnpDeviceDescriptionParser()
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = delegate
    XCTAssertTrue(parser.parse())
    XCTAssertEqual(delegate.friendlyName, "Kitchen Speaker")
    XCTAssertEqual(delegate.avTransportServiceType, "urn:schemas-upnp-org:service:AVTransport:1")
    XCTAssertEqual(delegate.avTransportControlUrl, "/MediaRenderer/AVTransport/Control")
  }

  // MARK: G25 Lidarr decoders

  func testLidarrArtistDecoding() {
    let json = """
      [{"foreignArtistId": "mbid-1", "artistName": "Neu!", "overview": "Krautrock"},
       {"artistName": "No MBID row"},
       {"foreignArtistId": "mbid-2", "artistName": "Can"}]
      """
    let artists = LidarrApiClient.decodeArtists(Data(json.utf8))
    XCTAssertEqual(artists.count, 2)
    XCTAssertEqual(artists[0].foreignArtistId, "mbid-1")
    XCTAssertEqual(artists[0].artistName, "Neu!")
    XCTAssertEqual(artists[1].foreignArtistId, "mbid-2")
  }

  func testLidarrFirstIdAndRootFolderDecoding() {
    XCTAssertEqual(LidarrApiClient.decodeFirstId(Data("[{\"id\": 4}, {\"id\": 9}]".utf8)), 4)
    XCTAssertNil(LidarrApiClient.decodeFirstId(Data("[]".utf8)))
    XCTAssertNil(LidarrApiClient.decodeFirstId(Data("not json".utf8)))
    let folders = LidarrApiClient.decodeIdPathPairs(
      Data("[{\"path\": \"/music\"}, {\"path\": \"/incoming\"}]".utf8)
    )
    XCTAssertEqual(folders, ["/music", "/incoming"])
  }
}
