//
//  ParametricEQSetting.swift
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

import AVFoundation
import Foundation

// MARK: - ParametricEQFilterType

/// Filter types of the parametric EQ (G22). The AutoEQ short codes are
/// kept as the Codable raw values so imported profile JSON decodes
/// straight into this enum.
public enum ParametricEQFilterType: String, CaseIterable, Sendable, Codable {
  case peak = "PK"
  case lowShelf = "LS"
  case highShelf = "HS"

  public var avAudioUnitEQFilterType: AVAudioUnitEQFilterType {
    switch self {
    case .peak: return .parametric
    case .lowShelf: return .lowShelf
    case .highShelf: return .highShelf
    }
  }
}

// MARK: - ParametricEQBand

/// One band of a parametric EQ profile (G22) — a biquad described by
/// its AutoEQ-style parameters: center/corner frequency, gain and Q.
public struct ParametricEQBand: Hashable, Sendable, Codable {
  /// `AVAudioUnitEQ` hardware limits: gain ±24 dB, frequency
  /// 20…22050 Hz, bandwidth 0.05…3.0 octaves
  public static let minGainDb = -24.0
  public static let maxGainDb = 24.0
  public static let minFrequency = 20.0
  public static let maxFrequency = 22_050.0
  public static let minBandwidthOctaves = 0.05
  public static let maxBandwidthOctaves = 3.0
  /// Q corresponding to a 1-octave bandwidth: `Q = √2^N / (2^N − 1)`
  /// with N = 1 → √2 ≈ 1.414
  public static let oneOctaveQ = sqrt(2.0)

  /// center frequency (peak) or corner frequency (shelves) in Hz
  public var frequency: Double
  /// gain in dB (positive = boost)
  public var gainDb: Double
  /// quality factor — only `.peak` bands use it; shelves ignore it
  /// (the shelf slope is fixed inside `AVAudioUnitEQ`)
  public var q: Double
  public var filterType: ParametricEQFilterType

  public init(
    frequency: Double,
    gainDb: Double,
    q: Double,
    filterType: ParametricEQFilterType
  ) {
    self.frequency = frequency
    self.gainDb = gainDb
    self.q = q
    self.filterType = filterType
  }

  /// Q → bandwidth in octaves: `BW = 2·asinh(1/(2Q)) / ln(2)`.
  /// Q = √2 yields exactly 1 octave (the legacy graphic bands' width);
  /// the result is clamped to the `AVAudioUnitEQ` range 0.05…3.0.
  public static func bandwidthOctaves(forQ q: Double) -> Double {
    guard q > 0 else { return 1.0 }
    let octaves = 2.0 * asinh(1.0 / (2.0 * q)) / log(2.0)
    return min(max(octaves, minBandwidthOctaves), maxBandwidthOctaves)
  }

  public var bandwidthOctaves: Double {
    Self.bandwidthOctaves(forQ: q)
  }

  public var clampedFrequency: Float {
    Float(min(max(frequency, Self.minFrequency), Self.maxFrequency))
  }

  public var clampedGainDb: Float {
    Float(min(max(gainDb, Self.minGainDb), Self.maxGainDb))
  }
}

// MARK: - ParametricEQSetting

/// A parametric EQ profile (G22): named set of biquad bands plus a
/// preamp. The preamp is applied on `AVAudioUnitEQ.globalGain` (dB), so
/// AutoEQ's negative preamp (headroom against clipping) maps directly.
public struct ParametricEQSetting: Hashable, Sendable, Codable {
  public let id: UUID
  public var name: String
  /// preamp/attenuation in dB — clamped to the ±24 dB node limit
  public var preampDb: Double
  public var bands: [ParametricEQBand]

  public init(
    id: UUID = UUID(),
    name: String,
    preampDb: Double = 0.0,
    bands: [ParametricEQBand] = []
  ) {
    self.id = id
    self.name = name
    self.preampDb = preampDb
    self.bands = bands
  }

  public var description: String {
    name
  }

  public var clampedPreampDb: Float {
    Float(min(max(preampDb, ParametricEQBand.minGainDb), ParametricEQBand.maxGainDb))
  }

  /// band count the `AVAudioUnitEQ` node must expose — `numberOfBands`
  /// is fixed at node creation, so this defines the node's required
  /// shape. `max(1, …)` guards against a zero-band node.
  public var requiredBandCount: Int {
    max(1, bands.count)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  public static func == (
    lhs: ParametricEQSetting,
    rhs: ParametricEQSetting
  )
    -> Bool {
    lhs.id == rhs.id
  }
}

// MARK: - EqualizerProfile

/// One EQ the engine can apply (G22): either a legacy 10-band graphic
/// `EqualizerSetting` or a `ParametricEQSetting`. Both kinds coexist —
/// the apply site switches on the kind, and per-route overrides can
/// point at either.
public enum EqualizerProfile: Sendable {
  case graphic(EqualizerSetting)
  case parametric(ParametricEQSetting)

  public var name: String {
    switch self {
    case .graphic(let setting): return setting.name
    case .parametric(let setting): return setting.name
    }
  }

  /// band count the EQ node must expose for this profile
  public var requiredBandCount: Int {
    switch self {
    case .graphic: return EqualizerSetting.frequencies.count
    case .parametric(let setting): return setting.requiredBandCount
    }
  }
}

// MARK: - EqualizerSetting → parametric

extension EqualizerSetting {
  /// The fixed-10 graphic curve as an equivalent parametric profile —
  /// lossless: same center frequencies and gains on peak filters whose
  /// Q reproduces the legacy 1-octave bandwidth (√2), and the graphic's
  /// automatic gain compensation becomes the preamp.
  public var asParametricEQSetting: ParametricEQSetting {
    ParametricEQSetting(
      name: name,
      preampDb: Double(gainCompensation),
      bands: zip(Self.frequencies, gains).map { frequency, gain in
        ParametricEQBand(
          frequency: Double(frequency),
          gainDb: Double(gain),
          q: ParametricEQBand.oneOctaveQ,
          filterType: .peak
        )
      }
    )
  }
}
