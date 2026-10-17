import Foundation
import UniformTypeIdentifiers

enum MIMEType {
    private static let table: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8",
        "webmanifest": "application/manifest+json; charset=utf-8",
        "xml": "application/xml; charset=utf-8",
        "txt": "text/plain; charset=utf-8",
        "md": "text/markdown; charset=utf-8",
        "csv": "text/csv; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "heic": "image/heic",
        "ico": "image/x-icon",
        "bmp": "image/bmp",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "mp3": "audio/mpeg",
        "m4a": "audio/mp4",
        "aac": "audio/aac",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "flac": "audio/flac",
        "mp4": "video/mp4",
        "m4v": "video/x-m4v",
        "mov": "video/quicktime",
        "webm": "video/webm",
        "m3u8": "application/vnd.apple.mpegurl",
        "ts": "video/mp2t",
        "pdf": "application/pdf",
        "wasm": "application/wasm",
        "zip": "application/zip",
        "glb": "model/gltf-binary",
        "gltf": "model/gltf+json",
        "usdz": "model/vnd.usdz+zip",
    ]

    static func forExtension(_ ext: String) -> String {
        let ext = ext.lowercased()
        if let type = table[ext] {
            return type
        }
        if let type = UTType(filenameExtension: ext)?.preferredMIMEType {
            return type
        }
        return "application/octet-stream"
    }
}
