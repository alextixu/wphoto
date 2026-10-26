import Foundation
import ImageIO
import UIKit

struct InfoRow: Identifiable, Hashable {
    /// 本地化字串的 key（Localizable.strings）
    let label: String
    let value: String
    var id: String { label + value }
}

/// 以 ImageIO 解碼：JPEG / HEIF / 各家 RAW（RAF、ARW、CR3…）iOS 原生支援，不需第三方函式庫
enum ImageLoading {
    /// 縮圖：優先取用 RAW/JPEG 內嵌的預覽（快），沒有才從影像產生
    static func thumbnail(url: URL, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 檢視用大圖：以最長邊 maxPixel 解碼（RAW 走 Apple 的 RAW 管線）；maxPixel 為 nil 時用原始解析度
    static func fullImage(url: URL, maxPixel: Int? = nil) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixel { opts[kCGImageSourceThumbnailMaxPixelSize] = maxPixel }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - 拍攝資訊

    static func metadata(url: URL) -> [InfoRow] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return [] }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        var rows: [InfoRow] = []
        func add(_ label: String, _ value: String?) {
            if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                rows.append(InfoRow(label: label, value: v))
            }
        }
        func num(_ dict: [CFString: Any], _ key: CFString) -> Double? {
            (dict[key] as? NSNumber)?.doubleValue
        }

        add("Camera", tiff[kCGImagePropertyTIFFModel] as? String)
        add("Make", tiff[kCGImagePropertyTIFFMake] as? String)
        add("Lens", (exif[kCGImagePropertyExifLensModel] as? String) ?? (aux[kCGImagePropertyExifAuxLensModel] as? String))
        add("DateTaken", exif[kCGImagePropertyExifDateTimeOriginal] as? String)
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first {
            add("ISO", "\(iso.intValue)")
        }
        if let t = num(exif, kCGImagePropertyExifExposureTime) { add("Shutter", formatShutter(t)) }
        if let f = num(exif, kCGImagePropertyExifFNumber) { add("Aperture", String(format: "f/%g", f)) }
        if let fl = num(exif, kCGImagePropertyExifFocalLength) { add("FocalLength", String(format: "%g mm", fl)) }
        if let fl35 = num(exif, kCGImagePropertyExifFocalLenIn35mmFilm) { add("FocalLength35", String(format: "%g mm", fl35)) }
        if let ev = num(exif, kCGImagePropertyExifExposureBiasValue) { add("ExposureComp", String(format: "%+g EV", ev)) }
        if let p = num(exif, kCGImagePropertyExifExposureProgram) { add("ExposureMode", exposureProgramName(Int(p))) }
        if let m = num(exif, kCGImagePropertyExifMeteringMode) { add("Metering", meteringName(Int(m))) }
        if let wb = num(exif, kCGImagePropertyExifWhiteBalance) { add("WhiteBalance", wb == 0 ? "Auto" : "Manual") }
        if let fl = num(exif, kCGImagePropertyExifFlash) { add("Flash", (Int(fl) & 1) == 1 ? "Fired" : "Did not fire") }
        if let cs = num(exif, kCGImagePropertyExifColorSpace) { add("ColorSpace", Int(cs) == 1 ? "sRGB" : "Uncalibrated") }
        add("Software", tiff[kCGImagePropertyTIFFSoftware] as? String)
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            add("ImageSize", "\(w) x \(h)")
        }
        if var lat = num(gps, kCGImagePropertyGPSLatitude), var lon = num(gps, kCGImagePropertyGPSLongitude) {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
            add("GPS", String(format: "%.6f, %.6f", lat, lon))
        }
        return rows
    }

    static func formatShutter(_ seconds: Double) -> String {
        if seconds >= 1 { return String(format: "%g s", seconds) }
        if seconds > 0 { return "1/\(Int((1 / seconds).rounded())) s" }
        return "\(seconds)"
    }

    private static func exposureProgramName(_ v: Int) -> String {
        switch v {
        case 1: return "Manual"
        case 2: return "Program"
        case 3: return "Aperture priority"
        case 4: return "Shutter priority"
        case 5: return "Creative"
        case 6: return "Action"
        case 7: return "Portrait"
        case 8: return "Landscape"
        default: return "Unknown"
        }
    }

    private static func meteringName(_ v: Int) -> String {
        switch v {
        case 1: return "Average"
        case 2: return "Center-weighted"
        case 3: return "Spot"
        case 4: return "Multi-spot"
        case 5: return "Multi-segment"
        case 6: return "Partial"
        default: return "Unknown"
        }
    }
}
