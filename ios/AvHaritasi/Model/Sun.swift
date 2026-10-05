import Foundation

/// Gün doğumu / batımı (NOAA "sunrise equation" yaklaşımı, ±1-2 dk).
enum Sun {
    static func times(on date: Date, latitude: Double, longitude: Double,
                      calendar: Calendar = .current) -> (sunrise: Date, sunset: Date)? {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let noonUTC = utc.date(from: DateComponents(year: comps.year, month: comps.month, day: comps.day, hour: 12)) else {
            return nil
        }
        let rad = Double.pi / 180
        let jd = noonUTC.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let n = (jd - 2_451_545.0 + 0.0008).rounded()
        let jStar = n - longitude / 360
        let m = (357.5291 + 0.98560028 * jStar).truncatingRemainder(dividingBy: 360)
        let c = 1.9148 * sin(m * rad) + 0.0200 * sin(2 * m * rad) + 0.0003 * sin(3 * m * rad)
        let lambda = (m + c + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let jTransit = 2_451_545.0 + jStar + 0.0053 * sin(m * rad) - 0.0069 * sin(2 * lambda * rad)
        let sinDecl = sin(lambda * rad) * sin(23.4397 * rad)
        let cosDecl = cos(asin(sinDecl))
        let cosW = (sin(-0.833 * rad) - sin(latitude * rad) * sinDecl) / (cos(latitude * rad) * cosDecl)
        guard abs(cosW) <= 1 else { return nil }
        let w = acos(cosW) / rad
        let toDate = { (j: Double) in Date(timeIntervalSince1970: (j - 2_440_587.5) * 86_400) }
        return (toDate(jTransit - w / 360), toDate(jTransit + w / 360))
    }
}
