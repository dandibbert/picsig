import UIKit
import CoreImage
import PicSigCore

/// Turns a stitched image plus an `EditState` into the final bitmap.
///
/// The order matters: crop and rotate first so every later coordinate refers to
/// what the user sees, then tone adjustments, then masking (so a mask cannot be
/// undone by a later filter), then annotations and the watermark on top.
enum ImageComposer {
    static func compose(base: UIImage, state: EditState, targetSize: PixelSize? = nil) -> UIImage {
        var image = base

        if state.crop != .full {
            image = cropped(image, to: state.crop)
        }
        if state.quarterTurns != 0 || state.isMirrored {
            image = oriented(image, quarterTurns: state.quarterTurns, mirrored: state.isMirrored)
        }
        if !state.adjustments.isNeutral {
            image = adjusted(image, with: state.adjustments)
        }
        if let targetSize, !targetSize.isEmpty {
            image = image.resized(to: targetSize)
        }
        if !state.redactions.isEmpty {
            let plan = RedactionPlan(items: state.redactions,
                                     imageSize: PixelSize(width: Int(image.size.width),
                                                          height: Int(image.size.height)))
            image = RedactionRenderer.apply(plan: plan, to: image)
        }
        if !state.annotations.isEmpty || state.watermark != nil {
            image = decorated(image, state: state)
        }
        return image
    }

    // MARK: - Steps

    static func cropped(_ image: UIImage, to crop: NormalizedRect) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let rect = crop.scaled(to: cgImage.pixelSize)
        guard !rect.isEmpty, let cropped = cgImage.cropping(to: rect.cgRect) else { return image }
        return UIImage(cgImage: cropped)
    }

    static func oriented(_ image: UIImage, quarterTurns: Int, mirrored: Bool) -> UIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 || mirrored else { return image }
        let swapped = turns % 2 == 1
        let size = swapped ? CGSize(width: image.size.height, height: image.size.width) : image.size

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            cgContext.rotate(by: CGFloat(turns) * .pi / 2)
            if mirrored { cgContext.scaleBy(x: -1, y: 1) }
            image.draw(in: CGRect(x: -image.size.width / 2,
                                  y: -image.size.height / 2,
                                  width: image.size.width,
                                  height: image.size.height))
        }
    }

    static func adjusted(_ image: UIImage, with adjustments: ImageAdjustments) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        var ciImage = CIImage(cgImage: cgImage)

        ciImage = ciImage.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: adjustments.brightness,
            kCIInputContrastKey: adjustments.contrast,
            kCIInputSaturationKey: adjustments.saturation
        ])
        if adjustments.temperature != 0 {
            // 6500K is neutral; the slider moves +-1500K.
            let target = 6500 - adjustments.temperature * 1500
            ciImage = ciImage.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: target, y: 0)
            ])
        }
        if adjustments.sharpness > 0 {
            ciImage = ciImage.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: adjustments.sharpness * 1.5
            ])
        }
        if adjustments.vignette > 0 {
            ciImage = ciImage.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: adjustments.vignette * 2,
                kCIInputRadiusKey: 1.4
            ])
        }

        guard let output = RedactionRenderer.sharedCIContext.createCGImage(ciImage, from: ciImage.extent) else {
            return image
        }
        return UIImage(cgImage: output)
    }

    static func decorated(_ image: UIImage, state: EditState) -> UIImage {
        let size = image.size
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            AnnotationRenderer.draw(annotations: state.annotations, in: size, context: context)
            if let watermark = state.watermark {
                AnnotationRenderer.draw(watermark: watermark, in: size, context: context)
            }
        }
    }
}
