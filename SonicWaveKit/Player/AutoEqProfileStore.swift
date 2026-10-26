//
//  AutoEqProfileStore.swift
//  SonicWaveKit
//
//  Created by Alzimer Ahmed on 26.10.26.
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
import os.log

// MARK: - AutoEqProfileStore

/// Loads the bundled AutoEQ-style parametric correction profiles
/// (`Assets/AutoEqProfiles.json`) into `ParametricEQSetting`s (G22).
///
/// Provenance: the JSON is a *curated subset* of the community AutoEQ
/// dataset (github.com/jaakkopasanen/AutoEq — oratory1990/crinacle-style
/// Harman-target parametric corrections). The values are representative
/// AutoEQ-style filters (a low-shelf bass lift toward the Harman target
/// plus a handful of peaking cuts/boosts), not verbatim measurement
/// dumps — they were written for this bundle and should be refreshed
/// from upstream AutoEq exports when accuracy matters.
public enum AutoEqProfileStore {
  /// `[{name, preamp, filters:[{type:"PK|LS|HS", fc, gain, q}]}]` —
  /// the upstream `headphone` field is intentionally not decoded; the
  /// profile `name` already carries it
  private struct ProfileDTO: Decodable {
    let name: String
    let preamp: Double
    let filters: [FilterDTO]
  }

  private struct FilterDTO: Decodable {
    let type: String
    let fc: Double
    let gain: Double
    let q: Double
  }

  /// the bundled profiles, decoded once — the file is read-only
  public static let profiles: [ParametricEQSetting] = loadProfiles(bundle: Bundle(for: BundleToken.self))

  /// reads + parses `AutoEqProfiles.json` from the kit bundle
  public static func loadProfiles() -> [ParametricEQSetting] {
    loadProfiles(bundle: Bundle(for: BundleToken.self))
  }

  /// the bundle parameter keeps the loader testable
  static func loadProfiles(bundle: Bundle) -> [ParametricEQSetting] {
    guard let url = bundle.url(forResource: "AutoEqProfiles", withExtension: "json") else {
      os_log(.error, "AutoEQ: AutoEqProfiles.json missing from bundle")
      return []
    }
    guard let data = try? Data(contentsOf: url) else {
      os_log(.error, "AutoEQ: AutoEqProfiles.json unreadable")
      return []
    }
    return parse(data: data)
  }

  /// decodes the AutoEQ JSON shape into parametric profiles; filters
  /// with an unknown `type` are dropped, an unparsable file yields `[]`
  public static func parse(data: Data) -> [ParametricEQSetting] {
    guard let dtos = try? JSONDecoder().decode([ProfileDTO].self, from: data) else {
      os_log(.error, "AutoEQ: profile JSON failed to decode")
      return []
    }
    return dtos.map { dto in
      ParametricEQSetting(
        name: dto.name,
        preampDb: dto.preamp,
        bands: dto.filters.compactMap { filter in
          guard let filterType = ParametricEQFilterType(rawValue: filter.type)
          else { return nil }
          return ParametricEQBand(
            frequency: filter.fc,
            gainDb: filter.gain,
            q: filter.q,
            filterType: filterType
          )
        }
      )
    }
  }

  private final class BundleToken {}
}
