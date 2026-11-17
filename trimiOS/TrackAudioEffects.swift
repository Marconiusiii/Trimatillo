import Foundation

nonisolated struct TrackAudioEffects: Codable, Equatable {
	struct Loudness: Codable, Equatable {
		var target = -16.0
		var peak = -1.0
	}
	struct Smoothing: Codable, Equatable {
		var threshold = -18.0
		var ratio = 3.0
	}
	var loudness: Loudness?
	var smoothing: Smoothing?

	var isValid: Bool {
		if let loudness, !(-30 ... -10).contains(loudness.target) || !(-9 ... -1).contains(loudness.peak) { return false }
		if let smoothing, !(-40 ... 0).contains(smoothing.threshold) || !(1 ... 10).contains(smoothing.ratio) { return false }
		return true
	}
}

// Stereo-linked compression keeps the stereo image stable as the level changes.
nonisolated struct TrackDynamics {
	private var threshold = 1.0
	private var exponent = 0.0
	private var attack = 0.0
	private var release = 0.0
	private var envelope = 0.0
	private let limit = pow(10.0, -1.0 / 20)
	private(set) var enabled = false

	mutating func configure(_ smoothing: TrackAudioEffects.Smoothing?, rate: Double) {
		enabled = smoothing != nil
		guard let smoothing, rate > 0 else { envelope = 0; return }
		threshold = pow(10, smoothing.threshold / 20)
		exponent = 1 / smoothing.ratio - 1
		attack = exp(-1 / (rate * 0.020))
		release = exp(-1 / (rate * 0.250))
	}

	mutating func gain(left: Double, right: Double) -> Double {
		let level = max(abs(left), abs(right))
		let coefficient = level > envelope ? attack : release
		envelope = coefficient * envelope + (1 - coefficient) * level
		let compressed = envelope > threshold ? pow(envelope / threshold, exponent) : 1
		return level * compressed > limit ? limit / level : compressed
	}
}
