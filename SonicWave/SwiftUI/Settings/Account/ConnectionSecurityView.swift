//
//  ConnectionSecurityView.swift
//  SonicWave
//
//  Created by Alzimer Ahmed on 25.10.26.
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
import UniformTypeIdentifiers

// MARK: - ConnectionSecurityView

/// Per-account TLS security settings: opt-in trust for self-signed server
/// certificates (pinned trust-on-first-use — never a blanket trust-all) and
/// PKCS#12 client-certificate management for mTLS reverse proxies.
///
/// The view works in two modes via its callbacks:
/// - **account mode** (Account settings): `accountIdent` resolves to the
///   account's Keychain ident and `onAllowUntrustedChange` persists the flag
///   into `loginCredentials` + re-provides them to the backend API
/// - **pending mode** (Login screen): `accountIdent` is derived from the
///   currently entered server URL + username (nil until both are filled in)
///   and the flag lands on the pending `LoginCredentials`
struct ConnectionSecurityView: View {
  let splitPercentage = 0.25

  private let accountIdent: () -> String?
  private let onAllowUntrustedChange: (Bool) -> ()

  private let certificateStore = ClientCertificateStore()
  private let pinStore = ServerCertificatePinStore()

  @State
  private var allowUntrusted: Bool
  @State
  private var isCertificateInstalled = false
  @State
  private var isImporterPresented = false
  @State
  private var isPasswordPromptVisible = false
  @State
  private var pendingImportData: Data?
  @State
  private var certificatePassword = ""
  @State
  private var errorMessage: String?
  @State
  private var successMessage: String?

  init(
    accountIdent: @escaping () -> String?,
    allowUntrusted: Bool,
    onAllowUntrustedChange: @escaping (Bool) -> ()
  ) {
    self.accountIdent = accountIdent
    self.onAllowUntrustedChange = onAllowUntrustedChange
    _allowUntrusted = State(initialValue: allowUntrusted)
  }

  private func reload() {
    if let ident = accountIdent() {
      isCertificateInstalled = certificateStore.isInstalled(accountIdent: ident)
    } else {
      isCertificateInstalled = false
    }
  }

  private func importCertificate(data: Data) {
    pendingImportData = data
    certificatePassword = ""
    isPasswordPromptVisible = true
  }

  private func confirmImport() {
    guard let data = pendingImportData else { return }
    guard let ident = accountIdent() else {
      errorMessage = "Enter server URL and username first."
      pendingImportData = nil
      return
    }
    let result = certificateStore.save(
      pkcs12Data: data,
      passphrase: certificatePassword,
      accountIdent: ident
    )
    switch result {
    case .success:
      successMessage = "Client certificate installed."
      errorMessage = nil
    case .invalidPassphraseOrData:
      errorMessage = "Could not read the certificate — wrong password or invalid .p12/.pfx file."
      successMessage = nil
    case .keychainFailure, .unknownAccount:
      errorMessage = "The certificate could not be stored securely."
      successMessage = nil
    }
    pendingImportData = nil
    reload()
  }

  private func removeCertificate() {
    guard let ident = accountIdent() else { return }
    certificateStore.delete(accountIdent: ident)
    successMessage = "Client certificate removed."
    errorMessage = nil
    reload()
  }

  private func resetTrustedCertificates() {
    guard let ident = accountIdent() else { return }
    pinStore.deleteAll(accountIdent: ident)
    successMessage = "Trusted certificates reset — the next connection re-pins the server certificate."
    errorMessage = nil
  }

  var body: some View {
    ZStack {
      SettingsList {
        if let successMessage {
          InfoBannerView(message: successMessage, color: .success)
        }
        if let errorMessage {
          InfoBannerView(message: errorMessage, color: .error)
        }

        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Allow Untrusted Certificates",
              isOn: $allowUntrusted
            )
          },
          footer: "Trusts server certificates that iOS cannot verify, e.g. self-signed ones. The certificate's public key is pinned on first contact; a later change blocks the connection until you reset trusted certificates below. Only enable this for servers you control."
        )

        SettingsSection(
          content: {
            SettingsRow(
              title: "Client Certificate",
              orientation: .vertical,
              splitPercentage: splitPercentage
            ) {
              SecondaryText(isCertificateInstalled ? "Installed" : "Not installed")
            }
            SettingsButtonRow(
              title: isCertificateInstalled
                ? "Replace Client Certificate…"
                : "Import Client Certificate…"
            ) {
              errorMessage = nil
              successMessage = nil
              isImporterPresented = true
            }
            if isCertificateInstalled {
              SettingsButtonRow(title: "Remove Client Certificate", actionType: .destructive) {
                removeCertificate()
              }
            }
          },
          footer: "A PKCS#12 (.p12/.pfx) client certificate for servers or reverse proxies that require mutual TLS. It is stored in the Keychain and presented only to your server's URLs.",
          header: "Mutual TLS (mTLS)"
        )

        SettingsSection(
          content: {
            SettingsButtonRow(title: "Reset Trusted Certificates", actionType: .destructive) {
              resetTrustedCertificates()
            }
          },
          footer: "Clears the pinned certificates of this account. Use this when your server's self-signed certificate was rotated and the connection is being rejected."
        )
      }
    }
    .onChange(of: allowUntrusted) { _, newValue in
      onAllowUntrustedChange(newValue)
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [.pkcs12, .data],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case let .success(urls):
        guard let url = urls.first else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
          if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        if let data = try? Data(contentsOf: url) {
          importCertificate(data: data)
        } else {
          errorMessage = "The selected file could not be read."
          successMessage = nil
        }
      case let .failure(error):
        errorMessage = error.localizedDescription
        successMessage = nil
      }
    }
    .alert("Certificate Password", isPresented: $isPasswordPromptVisible) {
      SecureField("Password (empty for none)", text: $certificatePassword)
      Button("Import") { confirmImport() }
      Button("Cancel", role: .cancel) { pendingImportData = nil }
    } message: {
      Text("Enter the password protecting this client certificate.")
    }
    .onAppear { reload() }
    .navigationTitle("Connection Security")
    .navigationBarTitleDisplayMode(.inline)
  }
}

// MARK: - ConnectionSecurityView_Previews

struct ConnectionSecurityView_Previews: PreviewProvider {
  static var previews: some View {
    NavigationView {
      ConnectionSecurityView(accountIdent: { nil }, allowUntrusted: false) { _ in }
    }
  }
}
