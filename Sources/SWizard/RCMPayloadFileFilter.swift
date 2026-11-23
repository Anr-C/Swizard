import Foundation

enum RCMPayloadFileFilter {
    static func resolveSupportedURL(fromFileURLData data: Data) -> URL? {
        guard let url = URL(dataRepresentation: data, relativeTo: nil),
              url.isFileURL,
              url.pathExtension.lowercased() == "bin" else {
            return nil
        }

        return url
    }
}
