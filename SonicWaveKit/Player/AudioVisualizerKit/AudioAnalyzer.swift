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
  case skipSilence
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
    didSet {
      tapStateLock.withLock {
        tapState.isActive = !activeConsumers.isEmpty
        // skip-silence consumes only `rms` — the expensive FFT compute +
        // publish path runs just while a magnitudes consumer holds the tap
        tapState.needsFFT = !activeConsumers
          .isDisjoint(with: [.visualizer, .haptics])
      }
    }
  }

  public func requestActivation(for consumer: AudioAnalyzerConsumer) {
    activeConsumers.insert(consumer)
  }

  public func releaseActivation(for consumer: AudioAnalyzerConsumer) {
    activeConsumers.remove(consumer)
  }

  /// tap-side state read on the real-time render thread — one lock for
  /// all fields so `calculate` pays a single acquisition per buffer
  /// instead of three back-to-back ones
  private struct TapState {
    var isActive = false
    var isPlaying = false
    var sampleRate: Float = 0.0
    /// a magnitudes consumer (.visualizer/.haptics) holds the tap —
    /// without one only the cheap RMS path runs
    var needsFFT = false
    /// RMS publish throttle — counts buffers since the last publish
    var buffersSinceRmsPublish = 0
    /// FFT publish throttle — the magnitudes path publishes at ~57 Hz,
    /// not the ~170 Hz raw buffer rate (displays can't use it anyway)
    var buffersSinceFftPublish = 0
  }
  nonisolated(unsafe) private var tapState = TapState()
  private let tapStateLock = NSLock()

  nonisolated public var isActive: Bool {
    tapStateLock.withLock { tapState.isActive }
  }

  /// touched only by the tap's render thread (sole caller is
  /// `calculate`) — a plain `let`, no lock needed
  nonisolated(unsafe) private let fft: FFT

  /// RMS publishes at ~20 Hz in the skip-silence-only path — 256-frame
  /// buffers land at ~170 Hz (44.1 kHz), so every 8th buffer publishes;
  /// the 0.4 s silence gate needs nothing faster
  private static let rmsPublishEveryNthBuffer = 8
  /// Magnitudes/FFT publishes at ~57 Hz — every 3rd buffer at the
  /// ~170 Hz buffer rate; FFT compute + SwiftUI invalidation are skipped
  /// on the other two
  private static let fftPublishEveryNthBuffer = 3

  public init(fftSize: Int = 256, windowType: WindowType = .hannWindow) {
    self.fftSize = fftSize
    self.fft = FFT(size: fftSize, windowType: windowType)
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
    tapStateLock.withLock { tapState.sampleRate = sampleRate }
  }

  public func play() {
    tapStateLock.withLock { tapState.isPlaying = true }
  }

  public func stop() {
    tapStateLock.withLock { tapState.isPlaying = false }
    magnitudes = .init(repeating: .zero, count: fftSize / 2)
    // symmetric with magnitudes — a stopped feed must report silence,
    // not the last level it measured
    rms = .zero
  }

  nonisolated func calculate(buffer: AVAudioPCMBuffer, audioTime: AVAudioTime) {
    // one lock acquisition per buffer — the whole state snapshot plus
    // the RMS-throttle counter update happen under a single hold; nil
    // means this buffer publishes nothing
    let state = tapStateLock.withLock { () -> TapState? in
      guard tapState.isActive, tapState.isPlaying else { return nil }
      if tapState.needsFFT {
        tapState.buffersSinceFftPublish += 1
        guard tapState.buffersSinceFftPublish >= Self.fftPublishEveryNthBuffer
        else { return nil }
        tapState.buffersSinceFftPublish = 0
        return tapState
      }
      tapState.buffersSinceRmsPublish += 1
      guard tapState.buffersSinceRmsPublish >= Self.rmsPublishEveryNthBuffer
      else { return nil }
      tapState.buffersSinceRmsPublish = 0
      return tapState
    }
    guard let state, let data = buffer.floatChannelData else { return }

    if state.needsFFT {
      let magnitudesCalculated = fft.compute(
        sampleRate: state.sampleRate,
        audioData: data.pointee
      )
      let rmsCalculated = fft.rms(audioData: data.pointee)
      Task { @MainActor in
        self.magnitudes = magnitudesCalculated
        self.rms = rmsCalculated
      }
    } else {
      // skip-silence-only activation: the cheap vDSP RMS on every Nth
      // buffer replaces the per-buffer FFT compute + publish
      let rmsCalculated = fft.rms(audioData: data.pointee)
      Task { @MainActor in
        self.rms = rmsCalculated
      }
    }
  }
}
