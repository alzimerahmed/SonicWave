//
//  ParametricEQTest.swift
//  SonicWaveKitTests
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

@testable import SonicWaveKit
import AVFoundation
import XCTest

// MARK: - ParametricEQTest

/// G22 parametric EQ: the Q→bandwidth conversion, Codable round-trips,
/// the bundled AutoEQ profile store, route-map persistence and the
/// lossless graphic→parametric mapping.
class ParametricEQTest: XCTestCase {

  // MARK: Q → bandwidth in octaves

  func testBandwidthOctavesOneOctaveQ() {
    // Q = √2 must yield exactly one octave — the width the legacy
    // graphic bands used
    XCTAssertEqual(
      ParametricEQBand.bandwidthOctaves(forQ: sqrt(2.0)),
      1.0,
      accuracy: 0.001
    )
  }

  func testBandwidthOctavesTypicalValues() {
    XCTAssertEqual(
      ParametricEQBand.bandwidthOctaves(forQ: 1.0),
      1.389,
      accuracy: 0.01
    )
    XCTAssertEqual(
      ParametricEQBand.bandwidthOctaves(forQ: 0.71),
      1.89,
      accuracy: 0.01
    )
    XCTAssertEqual(
      ParametricEQBand.bandwidthOctaves(forQ: 4.31),
      0.334,
      accuracy: 0.01
    )
    XCTAssertEqual(
      ParametricEQBand.bandwidthOctaves(forQ: 10.0),
      0.144,
      accuracy: 0.01
    )
  }

  func testBandwidthOctavesClampsToNodeLimits() {
    // AVAudioUnitEQ accepts 0.05…3.0 octaves
    XCTAssertEqual(
      ParametricEQBand.bandwidthOctaves(forQ: 0.01),
      3.0,
      accuracy: 0.001
    )
    XCTAssertEqual(
      ParametricEQBand.bandwidthOctaves(forQ: 1_000_000),
      0.05,
      accuracy: 0.001
    )
  }

  func testBandwidthOctavesNonPositiveQIsSafe() {
    XCTAssertEqual(ParametricEQBand.bandwidthOctaves(forQ: 0), 1.0)
    XCTAssertEqual(ParametricEQBand.bandwidthOctaves(forQ: -2), 1.0)
  }

  // MARK: Model

  func testFilterTypeRawValuesMatchAutoEq() {
    // the AutoEq JSON carries the short codes directly
    XCTAssertEqual(ParametricEQFilterType.peak.rawValue, "PK")
    XCTAssertEqual(ParametricEQFilterType.lowShelf.rawValue, "LS")
    XCTAssertEqual(ParametricEQFilterType.highShelf.rawValue, "HS")
  }

  func testFilterTypeAvAudioUnitEQMapping() {
    XCTAssertEqual(ParametricEQFilterType.peak.avAudioUnitEQFilterType, .parametric)
    XCTAssertEqual(ParametricEQFilterType.lowShelf.avAudioUnitEQFilterType, .lowShelf)
    XCTAssertEqual(ParametricEQFilterType.highShelf.avAudioUnitEQFilterType, .highShelf)
  }

  func testParametricEQSettingCodableRoundTrip() throws {
    let original = ParametricEQSetting(
      name: "Test",
      preampDb: -6.4,
      bands: [
        ParametricEQBand(frequency: 105, gainDb: 6.4, q: 0.71, filterType: .lowShelf),
        ParametricEQBand(frequency: 64, gainDb: -2.0, q: 1.1, filterType: .peak),
        ParametricEQBand(frequency: 10000, gainDb: -5.0, q: 0.71, filterType: .highShelf),
      ]
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ParametricEQSetting.self, from: data)

    XCTAssertEqual(decoded.id, original.id)
    XCTAssertEqual(decoded.name, "Test")
    XCTAssertEqual(decoded.preampDb, -6.4, accuracy: 0.0001)
    XCTAssertEqual(decoded.bands.count, 3)
    XCTAssertEqual(decoded.bands[0].filterType, .lowShelf)
    XCTAssertEqual(decoded.bands[0].frequency, 105, accuracy: 0.0001)
    XCTAssertEqual(decoded.bands[1].q, 1.1, accuracy: 0.0001)
    XCTAssertEqual(decoded.bands[2].filterType, .highShelf)
  }

  func testClampsToNodeLimits() {
    // AVAudioUnitEQ limits: ±24 dB gain, 20…22050 Hz
    let band = ParametricEQBand(frequency: 5, gainDb: 40, q: 1, filterType: .peak)
    XCTAssertEqual(band.clampedFrequency, 20.0, accuracy: 0.001)
    XCTAssertEqual(band.clampedGainDb, 24.0, accuracy: 0.001)
    let setting = ParametricEQSetting(name: "x", preampDb: -60)
    XCTAssertEqual(setting.clampedPreampDb, -24.0, accuracy: 0.001)
  }

  func testRequiredBandCountGuardsZeroBands() {
    XCTAssertEqual(ParametricEQSetting(name: "x").requiredBandCount, 1)
    XCTAssertEqual(
      ParametricEQSetting(
        name: "x",
        bands: [
          ParametricEQBand(frequency: 100, gainDb: 0, q: 1, filterType: .peak),
        ]
      ).requiredBandCount,
      1
    )
    XCTAssertEqual(
      EqualizerSetting.off.asParametricEQSetting.requiredBandCount,
      EqualizerSetting.frequencies.count
    )
  }

  // MARK: AutoEqProfileStore

  func testAutoEqProfileStoreParsesLiteral() {
    let json = """
      [
        {
          "name": "Test Headphone",
          "headphone": "Test Headphone",
          "preamp": -5.0,
          "filters": [
            { "type": "LS", "fc": 80, "gain": 5.5, "q": 0.71 },
            { "type": "PK", "fc": 3000, "gain": -4.0, "q": 2.0 },
            { "type": "HS", "fc": 12000, "gain": -2.0, "q": 0.71 },
            { "type": "XX", "fc": 500, "gain": 1.0, "q": 1.0 }
          ]
        }
      ]
      """
    let profiles = AutoEqProfileStore.parse(data: Data(json.utf8))
    XCTAssertEqual(profiles.count, 1)
    XCTAssertEqual(profiles[0].name, "Test Headphone")
    XCTAssertEqual(profiles[0].preampDb, -5.0, accuracy: 0.0001)
    // the unknown "XX" filter type is dropped
    XCTAssertEqual(profiles[0].bands.count, 3)
    XCTAssertEqual(
      profiles[0].bands.map(\.filterType),
      [.lowShelf, .peak, .highShelf]
    )
  }

  func testAutoEqProfileStoreRejectsMalformed() {
    XCTAssertTrue(AutoEqProfileStore.parse(data: Data("[]".utf8)).isEmpty)
    XCTAssertTrue(AutoEqProfileStore.parse(data: Data("nope".utf8)).isEmpty)
  }

  func testAutoEqProfileStoreLoadsBundledResource() {
    // hosted tests embed SonicWaveKit.framework — the kit bundle must
    // expose AutoEqProfiles.json; a missing file regresses to []
    let profiles = AutoEqProfileStore.loadProfiles()
    XCTAssertFalse(profiles.isEmpty)
    XCTAssertTrue(profiles.contains { $0.name == "Sony WH-1000XM4" })
    XCTAssertTrue(profiles.allSatisfy { !$0.bands.isEmpty })
    // every bundled filter must decode into a known type (parse drops
    // unknowns silently — a dropped filter is still a non-empty band
    // list, so additionally check the band counts look AutoEq-sized)
    XCTAssertTrue(profiles.allSatisfy { $0.bands.count >= 3 })
  }

  // MARK: Route map persistence

  func testRouteEqualizerProfileMapRoundTrip() {
    var settings = UserSettings()
    XCTAssertEqual(settings.routeEqualizerProfileMap, [:])
    XCTAssertNil(settings.routeEqualizerMapJson)

    let map = [
      "Speaker:uid-1": "Sony WH-1000XM4",
      "BluetoothA2DP:uid-2": "Flat",
    ]
    settings.routeEqualizerProfileMap = map
    XCTAssertEqual(settings.routeEqualizerProfileMap, map)
    XCTAssertNotNil(settings.routeEqualizerMapJson)
  }

  func testRouteEqualizerProfileMapSurvivesUserSettingsEncode() throws {
    var settings = UserSettings()
    settings.routeEqualizerProfileMap = ["Speaker:uid-1": "Profile A"]
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(UserSettings.self, from: data)
    XCTAssertEqual(decoded.routeEqualizerProfileMap, ["Speaker:uid-1": "Profile A"])
  }

  func testRouteEqualizerProfileMapCorruptJsonFallsBack() {
    var settings = UserSettings()
    settings.routeEqualizerMapJson = "{corrupt"
    XCTAssertEqual(settings.routeEqualizerProfileMap, [:])
    // clearing the map drops the blob entirely
    settings.routeEqualizerProfileMap = [:]
    XCTAssertNil(settings.routeEqualizerMapJson)
  }

  func testRouteEqualizerMapDecodesWhenKeyAbsent() throws {
    // settings persisted before the key existed must still decode —
    // the Optional backing is what keeps them readable
    let settings = try JSONDecoder().decode(UserSettings.self, from: Data("{}".utf8))
    XCTAssertNil(settings.routeEqualizerMapJson)
    XCTAssertNil(settings.activeParametricEqualizerSetting)
    XCTAssertEqual(settings.parametricEqualizerSettings, [])
    XCTAssertEqual(settings.routeEqualizerProfileMap, [:])
  }

  // MARK: Graphic → parametric mapping

  func testGraphicToParametricMappingIsLossless() {
    for preset in EqualizerPreset.allCases {
      let graphic = preset.asEqualizerSetting
      let parametric = graphic.asParametricEQSetting

      XCTAssertEqual(parametric.name, graphic.name)
      XCTAssertEqual(parametric.bands.count, EqualizerSetting.frequencies.count)
      for (index, band) in parametric.bands.enumerated() {
        XCTAssertEqual(
          band.frequency,
          Double(EqualizerSetting.frequencies[index]),
          accuracy: 0.001
        )
        XCTAssertEqual(band.gainDb, Double(graphic.gains[index]), accuracy: 0.001)
        XCTAssertEqual(band.filterType, .peak)
        // √2 reproduces the graphic's fixed 1-octave bandwidth
        XCTAssertEqual(band.bandwidthOctaves, 1.0, accuracy: 0.001)
      }
      // the graphic's auto gain-compensation becomes the preamp
      XCTAssertEqual(
        parametric.preampDb,
        Double(graphic.gainCompensation),
        accuracy: 0.001
      )
    }
  }
}
