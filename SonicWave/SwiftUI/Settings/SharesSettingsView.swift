//
//  SharesSettingsView.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 28.02.26.
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

import SonicWaveKit
import SwiftUI

// MARK: - SharesSettingsView

/// G18: lists the account's public share links (`getShares`) with
/// copy-link and revoke. `publicUrlOverride` rewriting already happens
/// in the API layer — the URLs shown here are post-override. Revoke is
/// destructive and confirms per house style. `.notSupported` renders
/// an honest explanation, never an error banner.
struct SharesSettingsView: View {
  enum LoadState {
    case loading
    case loaded([ShareDescription])
    case notSupported
    /// fetch threw — distinct from "no shares": a failed load must not
    /// render the "No share links yet" empty state
    case failed
  }

  let accountInfo: AccountInfo

  @State
  private var loadState: LoadState = .loading
  @State
  private var sharePendingRevoke: ShareDescription?

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  private var backendApi: BackendApi {
    appDelegate.getMeta(accountInfo).backendApi
  }

  private func reload() {
    // keep prior content while refreshing — a failed refresh restores
    // the previous list instead of flashing the failed state
    let priorShares: [ShareDescription]? = {
      if case .loaded(let shares) = loadState { return shares }
      return nil
    }()
    if priorShares == nil { loadState = .loading }
    Task { @MainActor in
      do {
        switch try await backendApi.getShares() {
        case .supported(let shares):
          loadState = .loaded(shares)
        case .notSupported:
          loadState = .notSupported
        }
      } catch {
        appDelegate.eventLogger.report(topic: "Shares", error: error)
        loadState = priorShares.map { .loaded($0) } ?? .failed
      }
    }
  }

  private func revoke(_ share: ShareDescription) {
    Task { @MainActor in
      do {
        _ = try await backendApi.deleteShare(id: share.id)
        reload()
      } catch {
        appDelegate.eventLogger.report(topic: "Shares", error: error)
      }
    }
  }

  private func detailLine(for share: ShareDescription) -> String {
    var parts = [String]()
    if let created = share.created {
      parts.append(String(
        format: String(localized: "Created %@", comment: "Share list: creation date"),
        Self.dateFormatter.string(from: created)
      ))
    }
    if let expires = share.expires {
      let isExpired = expires < Date()
      parts.append(String(
        format: String(
          localized: isExpired ? "Expired %@" : "Expires %@",
          comment: "Share list: expiry date (tense changes on expiry)"
        ),
        Self.dateFormatter.string(from: expires)
      ))
    }
    if share.visitCount > 0 {
      parts.append(String(
        format: String(localized: "%lld visits", comment: "Share list: visit count"),
        share.visitCount
      ))
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    ZStack {
      SettingsList {
        switch loadState {
        case .loading:
          SettingsSection {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
          }
        case .notSupported:
          SettingsSection {
            SecondaryText(String(
              localized: "Sharing is not supported by this server.",
              comment: "Manage Shares: shown when the backend has no share API"
            ))
          }
        case .failed:
          SettingsSection {
            SecondaryText(String(
              localized: "Couldn't load share links. Check the connection and try again.",
              comment: "Manage Shares: shown when the share list fetch failed"
            ))
          }
        case .loaded(let shares):
          if shares.isEmpty {
            SettingsSection {
              SecondaryText(String(
                localized: "No share links yet. Create one from a song's, album's or playlist's actions menu.",
                comment: "Manage Shares: empty state hint"
              ))
            }
          } else {
            SettingsSection(
              content: {
                ForEach(shares, id: \.id) { share in
                  VStack(alignment: .leading, spacing: 2) {
                    Text(share.url)
                      .font(.footnote)
                      .lineLimit(1)
                      .truncationMode(.middle)
                    let detail = detailLine(for: share)
                    if !detail.isEmpty {
                      Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    if let description = share.description, !description.isEmpty {
                      Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                  }
                  .contextMenu {
                    Button {
                      UIPasteboard.general.string = share.url
                    } label: {
                      Label(
                        String(localized: "Copy Link", comment: "Manage Shares row action"),
                        systemImage: "doc.on.doc"
                      )
                    }
                    Button(role: .destructive) {
                      sharePendingRevoke = share
                    } label: {
                      Label(
                        String(localized: "Revoke", comment: "Manage Shares row action"),
                        systemImage: "trash"
                      )
                    }
                  }
                  .accessibilityHint(String(
                    localized: "Long-press for share actions",
                    comment: "VoiceOver hint on share rows"
                  ))
                }
              },
              footer: String(
                localized: "Share links are public — anyone with the URL can listen. Revoking deletes the link on the server.",
                comment: "Manage Shares footer"
              )
            )
          }
        }
      }
    }
    .navigationTitle(String(localized: "Manage Shares", comment: "Manage Shares screen title"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button {
          reload()
        } label: {
          AmperfyImage.refresh.asImage
        }
        .accessibilityLabel(String(
          localized: "Refresh Shares",
          comment: "VoiceOver label for the shares refresh button"
        ))
      }
    }
    .alert(item: $sharePendingRevoke) { share in
      Alert(
        title: Text(String(localized: "Revoke Share Link?", comment: "Revoke confirmation title")),
        message: Text(String(
          localized: "The public link stops working immediately.",
          comment: "Revoke confirmation body"
        )),
        primaryButton: .destructive(
          Text(String(localized: "Revoke", comment: "Revoke confirmation button"))
        ) {
          revoke(share)
        },
        secondaryButton: .cancel()
      )
    }
    .onAppear {
      if case .loading = loadState { reload() }
    }
  }
}
