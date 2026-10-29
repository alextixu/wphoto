import SwiftUI
import UIKit

/// 看劇模式的子資料夾：電影海報牆（直式 2:3 海報＋片名）。
/// LazyVGrid 只會建立畫面上看得到的海報，封面也只替這些資料夾讀；照片模式的資料夾維持 FolderGrid。
struct PosterGrid: View {
    let folders: [FolderSession.SubFolder]
    /// 不觀察：海報只在出現時向它要封面
    let session: FolderSession
    var large = false
    let onOpen: (FolderSession.SubFolder) -> Void

    var body: some View {
        let spacing: CGFloat = large ? 24 : 14
        // 格子靠上對齊：有年份的片名多一行，置中會讓同一排的海報上下錯開
        LazyVGrid(columns: [GridItem(.adaptive(minimum: large ? 160 : 104), spacing: spacing, alignment: .top)],
                  spacing: large ? 28 : 18) {
            ForEach(folders) { folder in
                Button { onOpen(folder) } label: {
                    PosterTile(folder: folder, session: session)
                }
                .buttonStyle(CardPressStyle())
                .wpHoverLift()
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: WPTheme.Radius.card, style: .continuous))
            }
        }
    }
}

struct PosterTile: View {
    let folder: FolderSession.SubFolder
    let session: FolderSession

    @State private var image: UIImage?
    /// 封面找完了（不論有沒有）：還沒找完先留空，才不會先閃一下佔位再換成封面
    @State private var finished = false

    /// 「片名 (年份)」：片名後接四位數年份（19xx／20xx）括號收尾
    private static let yearPattern = try? NSRegularExpression(pattern: "^(.*?)\\s*\\(((?:19|20)\\d{2})\\)\\s*$")
    private static let shape = RoundedRectangle(cornerRadius: WPTheme.Radius.card, style: .continuous)

    var body: some View {
        let parts = titleParts
        VStack(alignment: .leading, spacing: 6) {
            // 海報區尺寸只由 2:3 底色決定；圖片放 overlay 裡 scaledToFill 再裁切，不會撐大卡片
            Color.wpCard
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    } else if finished {
                        placeholder
                    }
                }
                .clipShape(Self.shape)
                .overlay(Self.shape.strokeBorder(Color.wpStroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 10, y: 6)

            Text(parts.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.wpLabel)
                .multilineTextAlignment(.leading)
                .lineLimit(2, reservesSpace: true)   // 片名區固定兩行高，整排海報對齊
                .frame(maxWidth: .infinity, alignment: .leading)
            if let year = parts.year {
                Text(year)
                    .font(.caption)
                    .foregroundStyle(Color.wpSecondaryLabel)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .animation(WPTheme.imageFade, value: image)
        .task(id: folder.url) {
            await load()
        }
    }

    /// 沒封面的佔位：用資料夾名決定色相的漸層＋首字母，同一部片每次開啟都同一個顏色。
    /// 用 djb2 而不是 hashValue：Swift 的 hashValue 每次啟動都換種子，顏色會跳
    private var placeholder: some View {
        let h = folder.name.unicodeScalars.reduce(5381) { ($0 &<< 5) &+ $0 &+ Int($1.value) }
        let hue = Double(h.magnitude % 360) / 360
        return ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.55),
                                    Color(hue: hue, saturation: 0.5, brightness: 0.25)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 6) {
                Text(String(folder.name.prefix(1)).uppercased())
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Image(systemName: "film.stack")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    /// 「Alpha (2024)」→ 片名「Alpha」＋年份「2024」；沒有年份就整個當片名
    private var titleParts: (title: String, year: String?) {
        let name = folder.name
        guard let regex = Self.yearPattern,
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let titleRange = Range(match.range(at: 1), in: name),
              let yearRange = Range(match.range(at: 2), in: name) else { return (name, nil) }
        let title = String(name[titleRange])
        // 整個名字只有「(2024)」：沒片名可拆，照原樣顯示
        guard !title.isEmpty else { return (name, nil) }
        return (title, String(name[yearRange]))
    }

    private func load() async {
        // 不論從哪條路徑結束（快取命中、取消、沒封面）都算找完，佔位才會出現
        defer { finished = true }
        if let cached = PosterCache.shared.object(forKey: folder.url as NSURL) {
            image = cached
            return
        }
        guard let source = await session.posterSource(for: folder), !Task.isCancelled else { return }
        let loaded: UIImage?
        switch source {
        case .image(let url):
            loaded = await Self.posterImage(url)
        case .video(let file):
            // 未下載的影片不截圖（ThumbnailCache 會略過），避免為了封面把整部影片下載下來
            loaded = await ThumbnailCache.shared.thumbnail(for: file, maxPixel: 640)
        }
        guard let loaded else { return }
        PosterCache.shared.setObject(loaded, forKey: folder.url as NSURL)
        image = loaded
    }

    /// 海報圖：從整張圖縮小（不用內嵌的小縮圖，太糊）；iCloud 上還沒下載的改用 iCloud 的縮圖
    private static func posterImage(_ url: URL) async -> UIImage? {
        let decoded = await Task.detached(priority: .utility) {
            ImageLoading.fullImage(url: url, maxPixel: 720)
        }.value
        if let decoded { return decoded }
        return await FileAvailability.remoteThumbnail(for: url, side: 360, scale: 2)
    }
}

/// 海報快取（以資料夾為 key）：捲回來不必再讀
enum PosterCache {
    static let shared: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 300
        return cache
    }()
}
