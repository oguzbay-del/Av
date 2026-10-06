import ActivityKit
import Foundation

/// Kilit ekranı / Dynamic Island / Apple Watch Akıllı Yığın'da gösterilen av durumu.
/// Hem uygulama hem AvDurumWidget eklentisi bu dosyayı derler.
struct HuntActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 0 bilinmiyor, 1 avlanabilir, 2 dikkat, 3 avlanmayın
        var level: Int
        var title: String
        var detail: String
        var wind: String?
        var updated: Date
    }

    var areaName: String
}
