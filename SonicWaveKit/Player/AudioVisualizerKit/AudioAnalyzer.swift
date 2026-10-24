import AVFoundation
import Observation
import SwiftUI

// MARK: - AudioAnalyzerProtocol

@MainActor
protocol AudioAnalyzerProtocol: AnyObject {
  func install(on audioNode: AVAudioNode)
  func playing(sampleRate: Float)
  func play()
  func stop()
}

// MARK: - AudioAnalyzerConsumer

/// Owner of an `AudioAnalyzer` tap activation — the FFT tap runs while
/// at least one consumer holds an activation, so the visualizer and
/// `MusicHapticsService` can't cut each other's feed by writing an
/// absolute `isActive`.
public enum AudioAnalyzerConsumer: Hashable {
  case visualizer
  case haptics
}

// MARK: - AudioAnalyzer

@MainActor
public final class AudioAnalyzer: ObservableObject, AudioAnalyzerProtocol {
  @Published
  public var magnitudes: [Magnitude]
  @Published
  public var rms: Float = .zero

  private let fftSize: Int

  /// consumers holding the tap live — idempotent per consumer, so
  /// request/release pairs may be issued unconditionally
  private var activeConsumers = Set<AudioAnalyzerConsumer>() {
    didSet { isActive = !activeConsumers.isEmpty }
  }

  public func requestActivation(for consumer: AudioAnalyzerConsumer) {
    activeConsumers.insert(consumer)
  }

  public func releaseActivation(for consumer: AudioAnalyzerConsumer) {
    activeConsumers.remove(consumer)
  }

  nonisolated(unsafe) private var _isActive = false
  private let _isActiveLock = NSLock()
  nonisolated public private(set) var isActive: Bool {
    get {
      _isActiveLock.withLock { _isActive }
    }
    set {
      _isActiveLock.withLock { _isActive = newValue }
    }
  }

  nonisolated(unsafe) private var _isPlaying = false
  private let _isPlayingLock = NSLock()
  nonisolated private var isPlaying: Bool {
    get {
      _isPlayingLock.withLock { _isPlaying }
    }
    set {
      _isPlayingLock.withLock { _isPlaying = newValue }
    }
  }

  nonisolated(unsafe) private var _sampleRate: Float = 0.0
  private let _sampleRateLock = NSLock()
  nonisolated private var sampleRate: Float {
    get {
      _sampleRateLock.withLock { _sampleRate }
    }
    set {
      _sampleRateLock.withLock { _sampleRate = newValue }
    }
  }

  nonisolated(unsafe) private var _fft: FFT
  private let _fftLock = NSLock()
  nonisolated private var fft: FFT {
    get {
      _fftLock.withLock { _fft }
    }
    set {
      _fftLock.withLock { _fft = newValue }
    }
  }

  public init(fftSize: Int = 256, windowType: WindowType = .hannWindow) {
    self.fftSize = fftSize
    self._fft = FFT(size: fftSize, windowType: windowType)
    self.magnitudes = .init(repeating: .zero, count: fftSize / 2)
  }

  public func install(on audioNode: AVAudioNode) {
    audioNode.installTap(
      onBus: .zero,
      bufferSize: AVAudioFrameCount(fftSize),
      format: nil,
      block: calculate
    )
  }

  public func playing(sampleRate: Float) {
    self.sampleRate = sampleRate
  }

  public func play() {
    isPlaying = true
  }

  public func stop() {
    isPlaying = false
    magnitudes = .init(repeating: .zero, count: fftSize / 2)
  }

  nonisolated func calculate(buffer: AVAudioPCMBuffer, audioTime: AVAudioTime) {
    if isActive, isPlaying, let data = buffer.floatChannelData {
      let magnitudesCalculated = fft.compute(sampleRate: sampleRate, audioData: data.pointee)
      let rmsCalculated = fft.rms(audioData: data.pointee)

      Task { @MainActor in
        self.magnitudes = magnitudesCalculated
        self.rms = rmsCalculated
      }
    }
  }
}
