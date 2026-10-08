import Foundation
import CoreText

/// VLC 字幕（freetype 文字渲染器）要用的字型。
///
/// libvlc 3 在 Apple 平台的預設字型是 "Helvetica Neue"，沒有中文字；遇到缺字時會用 CoreText 找替代字型，
/// 但 iOS 回傳的是系統內部、名稱以「.」開頭的 ".PingFang SC"，VLC 拿這個名稱到字型檔裡比對
/// （modules/text_renderer/freetype/fonts/darwin.c 的 getFontIndexInFontFile）會對不上，
/// 結果退回 Helvetica Neue，中文就變成方格。直接指定一般名稱的中文字型（例如 "PingFang TC"）就會走
/// 依名稱查找的流程，能正確載入。
enum SubtitleFont {
    /// 第一個 freetype 讀得到的中文字型家族；都找不到就回傳 nil（維持 VLC 預設）
    static let vlcFamily: String? = {
        candidates.first(where: isReadableByFreeType)
    }()

    /// 介面是簡體中文時先用簡體字形（SC），其他情況先用繁體字形（TC）；兩者都含完整的繁簡中文與英數字
    private static var candidates: [String] {
        let simplified = (Bundle.main.preferredLocalizations.first ?? "") == "zh-Hans"
        return simplified
            ? ["PingFang SC", "PingFang TC", "PingFang HK", "Heiti SC", "Heiti TC", "Hiragino Sans"]
            : ["PingFang TC", "PingFang SC", "PingFang HK", "Heiti TC", "Heiti SC", "Hiragino Sans"]
    }

    /// freetype 要能直接開啟字型檔：找得到這個家族、而且字型檔路徑可讀
    private static func isReadableByFreeType(_ family: String) -> Bool {
        let attributes = [kCTFontFamilyNameAttribute as String: family] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
        guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, nil),
              let matchedFamily = CTFontDescriptorCopyAttribute(matched, kCTFontFamilyNameAttribute) as? String,
              matchedFamily.caseInsensitiveCompare(family) == .orderedSame,
              let url = CTFontDescriptorCopyAttribute(matched, kCTFontURLAttribute) as? URL
        else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }
}
