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
        let spacing: CGFloat = large ? 20 : 12
        LazyVGrid(columns: [GridItem(.adaptive(minimum: large ? 160 : 104), spacing: spacing)],
                  spacing: large ? 24 : 16) {
            ForEach(folders) { folder in
                Button { onOpen(folder) } label: {
                    PosterTile(folder: folder, session: session)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct PosterTile: View {
    let folder: FolderSession.SubFolder
    let session: FolderSession

    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 海報區尺寸只由 2:3 底色決定；圖片放 overlay 裡 scaledToFill 再裁切，不會撐大卡片
            Color.wpCard
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "film.stack")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(folder.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2, reservesSpace: true)   // 片名區固定兩行高，整排海報對齊
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .task(id: folder.url) {
            await load()
        }
    }

    private func load() async {
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
