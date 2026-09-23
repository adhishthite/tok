import Foundation

/// Item C: capture finalization diagnostics. Everything here is measured, never estimated,
/// and reading it never changes what stopRecording waits for or when it wakes: this is one
/// more thing stopRecording reports about a wait it already ran, the same way peakDb and
/// speechFrames report on a clip it already captured.
struct CaptureFinalizeStats: Sendable {
  /// Which branch of stopRecording's trailing-capture wait produced this clip:
  /// - "none": gracePeriodMs <= 0, no wait at all.
  /// - "fixed": maxTrailMs <= gracePeriodMs, the plain `usleep(gracePeriodMs)` path.
  /// - "quiet": the adaptive loop's continuous-quiet condition was satisfied by a genuine
  ///   below-threshold level reading.
  /// - "quiet_stale": same as "quiet", but the level reading that made the loop's final
  ///   iteration count as not-speaking was stale (no buffer had refreshed lastLevelTime in
  ///   over 300ms) rather than a genuine reading under silenceThresholdDb.
  /// - "cap": the adaptive loop hit its hard maxTrailMs ceiling before quiet was satisfied.
  /// "interrupted" does not appear: turnInterrupted does not gate this wait loop in the
  /// current implementation (see AudioCaptureEngine.stopRecording), so an interrupted
  /// capture still exits via "none"/"fixed"/"quiet"/"quiet_stale"/"cap" like any other; the
  /// `interrupted` flag stopRecording already returns is the only signal for that.
  let exit: String
  /// Milliseconds spent in the `audioProcessingQueue.sync {}` drain that runs immediately
  /// before the adaptive loop reads its pre-loop quiet-frame count. 0 for "none" and "fixed",
  /// which never reach that drain.
  let drainMs: Double
  /// Milliseconds from stopRequestTime (entry to stopRecording) to leaving the
  /// trailing-capture wait, whichever branch ran.
  let trailWaitMs: Double
  /// quietFrames * 20: continuous quiet already banked in frameDbValues before the adaptive
  /// loop started polling. 0 for "none" and "fixed", which never compute quietFrames.
  let bankedQuietMs: Double
  /// Number of times the adaptive loop's quietStart went from non-nil back to nil (speech
  /// resumed after a quiet stretch) while it waited. 0 for "none" and "fixed".
  let quietResets: Int
  /// Max lastLevelDb sampled across the adaptive loop's iterations. nil if the loop did not
  /// run ("none" and "fixed").
  let trailPeakDb: Double?
  /// 10th percentile of every 20ms-frame dB value captured in this clip (frameDbValues,
  /// pre-roll frames included, same population speechFrames counts from). nil if fewer than
  /// 10 frames exist.
  let noiseFloorDb: Double?
}
