//
//  OutputTargetsVC.swift
//  SonicWave
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

import MediaPlayer
import SonicWaveKit
import UIKit

// MARK: - OutputTargetsVC

/// G11 (+G10 seam): "Play to" picker — local output (AirPlay), the
/// server-side jukebox, and UPnP/DLNA renderers discovered via SSDP.
/// Chromecast is intentionally absent: the Google Cast iOS SDK is
/// proprietary and not GPLv3-compatible to bundle (research.md ADR).
///
/// UPnP here is an honest "push current stream URL to renderer" —
/// the renderer fetches the stream itself; this is not remote-control
/// playback (no seek/volume), the row copy says so.
class OutputTargetsVC: UITableViewController {
  private let account: Account
  private var upnpDevices = [UpnpDevice]()
  private var isDiscovering = false
  /// non-nil when the LAN couldn't even be searched (entitlement or
  /// transport failure) — an empty `upnpDevices` alone means the scan
  /// ran and genuinely found nothing
  private var discoveryError: UpnpDiscovery.DiscoveryError?
  /// nil = still probing; server capability asked once per open
  private var jukeboxSupported: Bool?

  private let discovery = UpnpDiscovery()

  init(account: Account) {
    self.account = account
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var backendApi: BackendApi {
    appDelegate.getMeta(account.info).backendApi
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = String(localized: "Play To", comment: "Output target picker title")
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "outputCell")
    tableView.backgroundColor = .backgroundColor
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "arrow.clockwise"),
      style: .plain,
      target: self,
      action: #selector(rescan)
    )
    navigationItem.rightBarButtonItem?.accessibilityLabel = String(
      localized: "Rescan for devices",
      comment: "VoiceOver label for the UPnP rescan button"
    )

    probeJukebox()
    rescan()
  }

  private func probeJukebox() {
    Task { @MainActor in
      do {
        jukeboxSupported = try await backendApi.getJukeboxPlaylist().isSupported
      } catch {
        jukeboxSupported = false
      }
      tableView.reloadData()
    }
  }

  @objc
  private func rescan() {
    // re-entrancy guard — rapid Rescan taps must not stack
    // overlapping `discover()` tasks
    guard !isDiscovering else { return }
    isDiscovering = true
    discoveryError = nil
    navigationItem.rightBarButtonItem?.isEnabled = false
    tableView.reloadData()
    Task { @MainActor in
      do {
        upnpDevices = try await discovery.discover()
      } catch let error as UpnpDiscovery.DiscoveryError {
        upnpDevices = []
        discoveryError = error
      } catch {
        upnpDevices = []
        discoveryError = .transportFailed(String(describing: error))
      }
      isDiscovering = false
      navigationItem.rightBarButtonItem?.isEnabled = true
      tableView.reloadData()
    }
  }

  private func playOnRenderer(_ device: UpnpDevice) {
    guard let playable = appDelegate.player.currentlyPlaying else {
      appDelegate.eventLogger.info(
        topic: "UPnP",
        message: "Nothing is playing — start a track first.",
        displayPopup: true
      )
      return
    }
    Task { @MainActor in
      do {
        let streamUrl = try await backendApi.generateUrl(
          forStreamingPlayable: playable.info,
          maxBitrate: appDelegate.player.activeStreamingBitrate ?? .noLimit,
          formatPreference: appDelegate.player.activeTranscodingFormat ?? .serverConfig,
          timeOffset: nil
        )
        try await UpnpAvTransport(device: device).play(
          uri: streamUrl,
          title: playable.title,
          creator: playable.creatorName
        )
        appDelegate.eventLogger.info(
          topic: "UPnP",
          message: "Playing on \"\(device.friendlyName)\".",
          displayPopup: true
        )
        dismiss(animated: true)
      } catch {
        appDelegate.eventLogger.report(topic: "UPnP", error: error)
      }
    }
  }

  // MARK: table

  private enum RowKind {
    case airplay
    case jukebox
    case upnp(Int)
    case discovering
    case upnpEmpty
    /// the scan itself failed (entitlement/transport) — distinct from
    /// a completed scan that found zero renderers
    case upnpUnavailable
  }

  private var rows: [RowKind] {
    var rows = [RowKind]()
    #if !targetEnvironment(macCatalyst)
      // MPVolumeView's route picker is the only working AirPlay UI —
      // its fake-tap produces a dead popup on Catalyst (Phase-10 note)
      rows.append(.airplay)
    #endif
    if jukeboxSupported == true {
      rows.append(.jukebox)
    }
    if isDiscovering {
      rows.append(.discovering)
    } else if discoveryError != nil {
      rows.append(.upnpUnavailable)
    } else if upnpDevices.isEmpty {
      rows.append(.upnpEmpty)
    } else {
      rows.append(contentsOf: upnpDevices.indices.map { .upnp($0) })
    }
    return rows
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    rows.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "outputCell", for: indexPath)
    var content = cell.defaultContentConfiguration()
    switch rows[indexPath.row] {
    case .airplay:
      content.text = String(localized: "This Device", comment: "Output target row: local output")
      content.secondaryText = String(
        localized: "AirPlay and Bluetooth outputs",
        comment: "Output target row detail: local output"
      )
      content.image = UIImage(systemName: "airplayaudio")
      cell.accessoryType = .disclosureIndicator
    case .jukebox:
      content.text = String(localized: "Server Jukebox", comment: "Output target row: jukebox")
      content.secondaryText = String(
        localized: "Play on the server's own output",
        comment: "Output target row detail: jukebox"
      )
      content.image = UIImage(systemName: "hifispeaker")
      cell.accessoryType = .disclosureIndicator
    case .discovering:
      content.text = String(
        localized: "Searching for UPnP devices…",
        comment: "Output target picker: discovery in progress"
      )
      content.secondaryText = nil
      content.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
      cell.accessoryType = .none
      cell.selectionStyle = .none
    case .upnpEmpty:
      content.text = String(
        localized: "No UPnP Renderers Found",
        comment: "Output target picker: scan completed, zero results"
      )
      content.secondaryText = String(
        localized: "DLNA devices need to be on the same network",
        comment: "Output target picker: zero results hint"
      )
      content.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
      cell.accessoryType = .none
      cell.selectionStyle = .none
    case .upnpUnavailable:
      if case .transportFailed? = discoveryError {
        content.text = String(
          localized: "UPnP Discovery Failed",
          comment: "Output target picker: scan error"
        )
        content.secondaryText = String(
          localized: "The network scan reported an error — try rescanning.",
          comment: "Output target picker: scan error hint"
        )
      } else {
        // `.multicastUnavailable` — honest about the entitlement, not
        // blaming the user's LAN
        content.text = String(
          localized: "UPnP Discovery Isn't Available",
          comment: "Output target picker: multicast entitlement missing"
        )
        content.secondaryText = String(
          localized: "This build is missing the multicast networking entitlement — nothing is wrong with your network.",
          comment: "Output target picker: multicast entitlement hint"
        )
      }
      content.image = UIImage(systemName: "antenna.radiowaves.left.and.right.slash")
      cell.accessoryType = .none
      cell.selectionStyle = .none
    case let .upnp(index):
      let device = upnpDevices[index]
      content.text = device.friendlyName
      content.secondaryText = String(
        localized: "Pushes the current track's stream URL",
        comment: "Output target row detail: UPnP renderer"
      )
      content.image = UIImage(systemName: "tv")
      cell.accessoryType = .none
      cell.selectionStyle = .default
    }
    cell.contentConfiguration = content
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    switch rows[indexPath.row] {
    case .airplay:
      // the MPVolumeView fake-tap — the only route picker iOS exposes
      let rect = CGRect(x: -100, y: 0, width: 0, height: 0)
      let airplayVolume = MPVolumeView(frame: rect)
      airplayVolume.showsVolumeSlider = false
      view.addSubview(airplayVolume)
      for sub in airplayVolume.subviews {
        if let button = sub as? UIButton {
          button.sendActions(for: .touchUpInside)
          break
        }
      }
      airplayVolume.removeFromSuperview()
    case .jukebox:
      navigationController?.pushViewController(JukeboxVC(account: account), animated: true)
    case let .upnp(index):
      playOnRenderer(upnpDevices[index])
    case .discovering, .upnpEmpty, .upnpUnavailable:
      break
    }
  }
}
