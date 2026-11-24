import Foundation
import Photos

enum PhotosExporter {
    /// Request add-only access. The first call triggers the system prompt.
    static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                completion(status == .authorized || status == .limited)
            }
        }
    }

    /// Create one Live Photo asset from a JPEG + MOV pair.
    static func importPair(jpg: URL, mov: URL, completion: @escaping (Error?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: jpg, options: options)
            request.addResource(with: .pairedVideo, fileURL: mov, options: options)
        }, completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(nil)
                } else {
                    completion(error ?? NSError(
                        domain: "PhotosExporter",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "导入照片图库失败"]))
                }
            }
        })
    }
}
