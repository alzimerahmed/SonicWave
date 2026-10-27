//
//  UpnpClient.swift
//  SonicWaveKit
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

import Foundation
import Network
import os.log

// MARK: - UpnpDevice

/// A discovered UPnP/DLNA media renderer with an AVTransport service —
/// the only UPnP profile we drive (`SetAVTransportURI`/`Play`).
public struct UpnpDevice: Sendable, Equatable, Identifiable {
  public var id: String { usn }
  public var usn: String
  public var friendlyName: String
  /// device description document URL (SSDP `LOCATION`)
  public var descriptionUrl: URL
  /// absolute AVTransport `controlURL` resolved against `descriptionUrl`
  public var avTransportControlUrl: URL
  public var avTransportServiceType: String

  public init(
    usn: String,
    friendlyName: String,
    descriptionUrl: URL,
    avTransportControlUrl: URL,
    avTransportServiceType: String
  ) {
    self.usn = usn
    self.friendlyName = friendlyName
    self.descriptionUrl = descriptionUrl
    self.avTransportControlUrl = avTransportControlUrl
    self.avTransportServiceType = avTransportServiceType
  }
}

// MARK: - SsdpMessages

/// Pure SSDP wire-format helpers (G11) — kept static for unit tests.
public enum SsdpMessages {
  public static let multicastHost = "239.255.255.250"
  public static let multicastPort = 1900
  public static let avTransportSearchTarget = "urn:schemas-upnp-org:service:AVTransport:1"

  /// SSDP M-SEARCH discovery datagram (UDP to the multicast group)
  public static func mSearchRequest(
    searchTarget: String = avTransportSearchTarget,
    maxWaitSeconds: Int = 2
  ) -> String {
    // header order + double CRLF terminator per UPnP DA §1.3.2
    "M-SEARCH * HTTP/1.1\r\n" +
      "HOST: \(multicastHost):\(multicastPort)\r\n" +
      "MAN: \"ssdp:discover\"\r\n" +
      "MX: \(maxWaitSeconds)\r\n" +
      "ST: \(searchTarget)\r\n" +
      "USER-AGENT: SonicWave/1.0 UPnP/1.0\r\n" +
      "\r\n"
  }

  /// Parses an M-SEARCH response / NOTIFY header block — headers are
  /// case-insensitive, values trimmed. Returns the fields we consume.
  public static func parseResponse(
    _ text: String
  ) -> (location: String?, usn: String?, st: String?, server: String?) {
    var location: String?
    var usn: String?
    var st: String?
    var server: String?
    for line in text.components(separatedBy: "\r\n") {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      switch name {
      case "location": location = value
        // ST on responses can carry the uuid suffix `::urn:…`/`::upnp:rootdevice`
      case "usn": usn = value.components(separatedBy: "::").first ?? value
      case "st", "nt": if st == nil { st = value }
      case "server": server = value
      default: break
      }
    }
    return (location, usn, st, server)
  }
}

// MARK: - UpnpSoap

/// Pure UPnP SOAP wire-format helpers — kept static for unit tests.
public enum UpnpSoap {
  /// SOAP 1.1 envelope for `serviceType#action` with an argument list.
  public static func actionBody(
    serviceType: String,
    action: String,
    arguments: [(name: String, value: String)]
  ) -> String {
    var args = ""
    for arg in arguments {
      args += "<\(arg.name)>\(escape(arg.value))</\(arg.name)>"
    }
    return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n" +
      "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " +
      "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\r\n" +
      "<s:Body><u:\(action) xmlns:u=\"\(escape(serviceType))\">\(args)</u:\(action)></s:Body>\r\n" +
      "</s:Envelope>"
  }

  /// `SOAPACTION` header value: `"serviceType#action"`
  public static func soapActionHeader(serviceType: String, action: String) -> String {
    "\"\(serviceType)#\(action)\""
  }

  /// DIDL-Lite metadata for `SetAVTransportURI` — renderers (Kodi,
  /// foobar, Smart TVs) show title/creator on their display.
  public static func avTransportUriMetadata(title: String, creator: String?) -> String {
    "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" " +
      "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
      "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">" +
      "<item id=\"0\" parentID=\"-1\" restricted=\"1\">" +
      "<dc:title>\(escape(title))</dc:title>" +
      (creator.map { "<dc:creator>\(escape($0))</dc:creator>" } ?? "") +
      "<upnp:class>object.item.audioItem.musicTrack</upnp:class>" +
      "</item></DIDL-Lite>"
  }

  public static func escape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}

// MARK: - UpnpDeviceDescriptionParser

/// Parses a UPnP device description document: `friendlyName` + the
/// AVTransport service's `controlURL` (resolved later against LOCATION).
/// Nested `<deviceList>` entries (media servers embedded in renderers)
/// are skipped — only the root device's own service list matters… and
/// for renderers AVTransport lives on the root device anyway.
final class UpnpDeviceDescriptionParser: NSObject, XMLParserDelegate {
  private(set) var friendlyName: String?
  private(set) var avTransportServiceType: String?
  private(set) var avTransportControlUrl: String?

  private var textBuffer = ""
  private var serviceDepth = 0
  private var currentServiceType = ""
  private var currentControlUrl = ""

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    textBuffer = ""
    if elementName == "service" { serviceDepth += 1 }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    textBuffer.append(string)
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    switch elementName {
    case "service":
      serviceDepth -= 1
      if avTransportServiceType == nil,
         currentServiceType.lowercased().contains("avtransport"),
         !currentControlUrl.isEmpty {
        avTransportServiceType = currentServiceType
        avTransportControlUrl = currentControlUrl
      }
      currentServiceType = ""
      currentControlUrl = ""
    case "friendlyName" where serviceDepth == 0 && friendlyName == nil:
      friendlyName = text
    case "serviceType" where serviceDepth > 0:
      currentServiceType = text
    case "controlURL" where serviceDepth > 0:
      currentControlUrl = text
    default:
      break
    }
    textBuffer = ""
  }
}

// MARK: - UpnpDiscovery

/// SSDP discovery for AVTransport renderers (G11) — M-SEARCH to the
/// UPnP multicast group, then description-document fetch per responder.
///
/// Platform caveat: iOS blocks multicast UDP without the
/// `com.apple.developer.networking.multicast` entitlement — unsigned CI
/// can't carry it, so discovery throws `DiscoveryError` instead of
/// pretending the LAN is empty (a manual-URL path is the documented
/// follow-up). An empty result genuinely means "searched, nothing
/// answered".
public actor UpnpDiscovery {
  private let log = OSLog(subsystem: "com.alzimerahmed.SonicWave", category: "UPnP")
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  /// Distinguishes "the network blocked us" from "no renderers on the
  /// LAN" so the picker can render an honest state for each.
  public enum DiscoveryError: Error, Sendable {
    /// the multicast group could not be joined — on device this is
    /// almost always the missing
    /// `com.apple.developer.networking.multicast` entitlement (needs a
    /// signed build); EPERM/EACCES from the listener lands here too
    case multicastUnavailable
    /// the joined group reported a transport error mid-listen
    case transportFailed(String)
  }

  /// `throws DiscoveryError` when the LAN can't even be searched —
  /// only an empty *success* means "searched, nothing answered"
  public func discover(timeoutSeconds: Double = 3.0) async throws -> [UpnpDevice] {
    do {
      let locations = try await collectLocations(timeoutSeconds: timeoutSeconds)
      var devices = [UpnpDevice]()
      for (location, usn) in locations {
        if let device = await fetchDevice(at: location, usn: usn) {
          devices.append(device)
        }
      }
      return devices
    } catch {
      os_log(
        "SSDP discovery failed: %{public}s",
        log: self.log,
        type: .info,
        String(describing: error)
      )
      throw error
    }
  }

  /// LOCATION headers from responders, deduplicated
  private func collectLocations(timeoutSeconds: Double) async throws -> [(URL, String?)] {
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(SsdpMessages.multicastHost),
      port: NWEndpoint.Port(rawValue: UInt16(clamping: SsdpMessages.multicastPort)) ?? 1900
    )
    let group: NWMulticastGroup
    do {
      group = try NWMulticastGroup(with: endpoint)
    } catch {
      // group creation is rejected without the multicast entitlement —
      // a capability failure, not "no renderers found"
      throw DiscoveryError.multicastUnavailable
    }
    let box = LocationBox()
    group.setReceiveHandler { _, content, error in
      // a missing multicast entitlement can also surface here (EPERM)
      // instead of at creation — record it so the timeout path throws
      // instead of reporting a falsely empty LAN
      if let error {
        box.record(error: Self.discoveryError(for: error))
        return
      }
      guard let content, let text = String(data: content, encoding: .utf8) else { return }
      let parsed = SsdpMessages.parseResponse(text)
      guard let raw = parsed.location, let url = URL(string: raw) else { return }
      box.append(url, usn: parsed.usn)
    }
    group.join(queue: .global(qos: .utility))
    defer { group.leave() }

    // send M-SEARCH on the group address — one datagram is enough;
    // responders are given MX seconds to answer
    let connection = NWConnection(to: endpoint, using: .udp)
    connection.start(queue: .global(qos: .utility))
    let request = SsdpMessages.mSearchRequest()
    connection.send(
      content: Data(request.utf8),
      completion: .contentProcessed { _ in }
    )

    defer { connection.cancel() }
    try await Task.sleep(for: .seconds(timeoutSeconds))
    if let error = box.firstError { throw error }
    return box.snapshot()
  }

  /// EPERM/EACCES on the listener = the multicast entitlement is
  /// missing on this build — that's "unavailable", not a LAN error
  private static func discoveryError(for error: NWError) -> DiscoveryError {
    if case .posix(let code) = error,
       code == .EPERM || code == .EACCES {
      return .multicastUnavailable
    }
    return .transportFailed(String(describing: error))
  }

  private func fetchDevice(at location: URL, usn: String?) async -> UpnpDevice? {
    do {
      var request = URLRequest(url: location)
      request.timeoutInterval = 10
      let (data, _) = try await session.data(for: request)
      let parser = UpnpDeviceDescriptionParser()
      let xmlParser = XMLParser(data: data)
      xmlParser.delegate = parser
      xmlParser.shouldResolveExternalEntities = false
      xmlParser.parse()
      guard let controlPath = parser.avTransportControlUrl,
            let serviceType = parser.avTransportServiceType,
            let controlUrl = URL(string: controlPath, relativeTo: location)?.absoluteURL,
            isSameOrigin(controlUrl, as: location)
      else { return nil }
      return UpnpDevice(
        usn: usn ?? location.absoluteString,
        friendlyName: parser.friendlyName ?? location.host ?? "UPnP renderer",
        descriptionUrl: location,
        avTransportControlUrl: controlUrl,
        avTransportServiceType: serviceType
      )
    } catch {
      return nil
    }
  }

  /// The control URL must stay on the device that answered M-SEARCH —
  /// a rogue responder could otherwise point us at a URL it controls
  /// and harvest the credentials embedded in the stream URI.
  private func isSameOrigin(_ url: URL, as other: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(),
          scheme == other.scheme?.lowercased(),
          let host = url.host?.lowercased(),
          host == other.host?.lowercased()
    else { return false }
    let port = url.port ?? (scheme == "https" ? 443 : 80)
    let otherScheme = other.scheme?.lowercased()
    let otherPort = other.port ?? (otherScheme == "https" ? 443 : 80)
    return port == otherPort
  }

  /// Lock-protected collector — the receive handler fires on a private
  /// queue while `discover` awaits on the actor.
  private final class LocationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<String>()
    private var entries = [(URL, String?)]()
    private var recordedError: DiscoveryError?

    func append(_ url: URL, usn: String?) {
      lock.lock()
      defer { lock.unlock() }
      let key = usn ?? url.absoluteString
      guard !seen.contains(key) else { return }
      seen.insert(key)
      entries.append((url, usn))
    }

    func record(error: DiscoveryError) {
      lock.lock()
      defer { lock.unlock() }
      if recordedError == nil { recordedError = error }
    }

    var firstError: DiscoveryError? {
      lock.lock()
      defer { lock.unlock() }
      return recordedError
    }

    func snapshot() -> [(URL, String?)] {
      lock.lock()
      defer { lock.unlock() }
      return entries
    }
  }
}

// MARK: - UpnpAvTransport

/// Minimal AVTransport control (G11): push a stream URL onto the
/// renderer and start playback. No queue/seek/volume — those need
/// PositionInfo polling and are deliberate follow-up scope.
public actor UpnpAvTransport {
  private let controlUrl: URL
  private let serviceType: String
  private let session: URLSession

  public init(controlUrl: URL, serviceType: String, session: URLSession = .shared) {
    self.controlUrl = controlUrl
    self.serviceType = serviceType
    self.session = session
  }

  public init(device: UpnpDevice, session: URLSession = .shared) {
    self.init(
      controlUrl: device.avTransportControlUrl,
      serviceType: device.avTransportServiceType,
      session: session
    )
  }

  /// `SetAVTransportURI` + `Play` — the renderer starts fetching the
  /// stream itself (server keeps serving it directly).
  public func play(uri: URL, title: String, creator: String? = nil) async throws {
    try await send(
      action: "SetAVTransportURI",
      arguments: [
        ("InstanceID", "0"),
        ("CurrentURI", uri.absoluteString),
        ("CurrentURIMetaData", UpnpSoap.avTransportUriMetadata(title: title, creator: creator)),
      ]
    )
    try await send(
      action: "Play",
      arguments: [("InstanceID", "0"), ("Speed", "1")]
    )
  }

  private func send(action: String, arguments: [(name: String, value: String)]) async throws {
    var request = URLRequest(url: controlUrl)
    request.httpMethod = "POST"
    request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
    request.setValue(
      UpnpSoap.soapActionHeader(serviceType: serviceType, action: action),
      forHTTPHeaderField: "SOAPACTION"
    )
    request.httpBody = Data(UpnpSoap.actionBody(
      serviceType: serviceType,
      action: action,
      arguments: arguments
    ).utf8)
    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
      throw BackendError.incorrectServerBehavior(
        message: "UPnP \(action) answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
      )
    }
  }
}
