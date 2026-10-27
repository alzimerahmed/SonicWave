//
//  TVArtworkImage.swift
//  SonicWaveTV
//
//  Created by Alzimer Ahmed on 28.10.26.
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
import UIKit

// MARK: - TVArtworkImage

/// Artwork with the house fallback chain: cached file → themed
/// generated placeholder (`getGeneratedArtwork`) — never a gray box.
/// Artwork radius is 5pt everywhere per the design system.
struct TVArtworkImage: View {
  let entity: AbstractLibraryEntity
  /// caller reads `settings.accounts.getSetting(entity.account?.info)`
  /// once — keeps per-account theming out of the view
  let themePreference: ThemePreference
  let artworkDisplayPreference: ArtworkDisplayPreference

  var body: some View {
    if let path = entity.imagePath(setting: artworkDisplayPreference),
       let image = UIImage(contentsOfFile: path) {
      Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: .fill)
    } else {
      Image(
        uiImage: .getGeneratedArtwork(
          theme: themePreference,
          artworkType: entity.getDefaultArtworkType()
        )
      )
      .resizable()
      .aspectRatio(contentMode: .fill)
    }
  }
}
