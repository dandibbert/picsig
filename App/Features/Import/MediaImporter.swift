import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PicSigCore

/// A movie copied out of the photo library into the app's temporary directory.
struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let fileExtension = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("PicSigVideo-\(UUID().uuidString.prefix(8)).\(fileExtension)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return VideoFile(url: copy)
        }
    }
}

enum MediaImporter {
    /// Loads picked photos, keeping the order the user selected them in.
    static func loadImages(from items: [PhotosPickerItem]) async -> [CGImage] {
        var results = [CGImage?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, CGImageBox?).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data),
                          let cgImage = image.normalizedCGImage() else {
                        return (index, nil)
                    }
                    return (index, CGImageBox(cgImage))
                }
            }
            for await (index, box) in group {
                results[index] = box?.image
            }
        }
        return results.compactMap { $0 }
    }

    static func loadVideo(from item: PhotosPickerItem) async throws -> URL? {
        try await item.loadTransferable(type: VideoFile.self)?.url
    }
}
