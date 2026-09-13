import AVFoundation
import CoreGraphics
import PicSigCore

/// Pulls frames out of a screen recording for the video-to-long-screenshot mode.
struct VideoFrameSampler {
    struct Options: Sendable {
        /// Frames sampled per second of recording.
        var framesPerSecond: Double
        /// Hard cap so a five minute recording cannot exhaust memory.
        var maximumFrameCount: Int
        /// Longest edge of the extracted frames; scrolling content does not need
        /// full resolution for alignment, but the output does, so this defaults to
        /// no downscaling.
        var maximumEdge: Int?
        /// Skip the first and last moments, which usually contain the recording
        /// indicator animation and the stop gesture.
        var leadingTrim: Double
        var trailingTrim: Double

        init(framesPerSecond: Double = 4,
             maximumFrameCount: Int = 240,
             maximumEdge: Int? = nil,
             leadingTrim: Double = 0.15,
             trailingTrim: Double = 0.1) {
            self.framesPerSecond = max(0.5, framesPerSecond)
            self.maximumFrameCount = max(2, maximumFrameCount)
            self.maximumEdge = maximumEdge
            self.leadingTrim = max(0, leadingTrim)
            self.trailingTrim = max(0, trailingTrim)
        }

        static let `default` = Options()
    }

    enum SamplerError: LocalizedError {
        case noVideoTrack
        case emptyDuration

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return NSLocalizedString("video.error.noTrack", comment: "")
            case .emptyDuration: return NSLocalizedString("video.error.emptyDuration", comment: "")
            }
        }
    }

    var options: Options = .default

    /// Extracted frames in capture order.
    func frames(from url: URL,
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> [CGImage] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw SamplerError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw SamplerError.emptyDuration }

        let start = min(options.leadingTrim, seconds / 4)
        let end = max(start + 0.05, seconds - min(options.trailingTrim, seconds / 4))
        let span = end - start

        var count = Int((span * options.framesPerSecond).rounded())
        count = max(2, min(count, options.maximumFrameCount))
        let step = span / Double(count - 1)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maximumEdge = options.maximumEdge {
            generator.maximumSize = CGSize(width: maximumEdge, height: maximumEdge)
        }

        var results = [CGImage]()
        results.reserveCapacity(count)
        for index in 0..<count {
            let time = CMTime(seconds: start + Double(index) * step, preferredTimescale: 600)
            do {
                let (image, _) = try await generator.image(at: time)
                results.append(image)
            } catch {
                // A single unreadable frame is not worth aborting the whole import.
                continue
            }
            progress?(Double(index + 1) / Double(count))
        }
        return results
    }
}
