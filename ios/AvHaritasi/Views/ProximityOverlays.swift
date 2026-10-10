import MapKit
import UIKit

/// GPS hassasiyet dairesi (yarıçap = yatay hassasiyet). MapKit'in mavi noktası ayrıca gösterilir.
final class AccuracyCircle: MKCircle {
    /// Hassasiyet kötü (> 50 m): turuncu çizilir.
    var degraded = false
}

/// Kullanıcıdan en yakın yasak alan noktasına kesikli çizgi.
final class BorderDistanceLine: MKPolyline {}

/// Hassasiyet dairesi ve sınır çizgisi katmanlarını yönetir (harita koordinatöründen bağımsız).
@MainActor
final class ProximityOverlayController {
    /// Bu değerin altında daire gizlenir (mavi nokta yeterli).
    static let minAccuracy: CLLocationAccuracy = 5
    /// Bu değerin üstünde daire turuncu olur.
    static let degradedAccuracy: CLLocationAccuracy = 50

    private var circle: AccuracyCircle?
    private var line: BorderDistanceLine?

    func apply(location: CLLocation?, borderTarget: CLLocationCoordinate2D?, on mv: MKMapView) {
        applyAccuracy(location, on: mv)
        applyLine(from: location?.coordinate, to: borderTarget, on: mv)
    }

    private func applyAccuracy(_ loc: CLLocation?, on mv: MKMapView) {
        guard let loc, loc.horizontalAccuracy >= Self.minAccuracy else {
            if let circle { mv.removeOverlay(circle); self.circle = nil }
            return
        }
        let degraded = loc.horizontalAccuracy > Self.degradedAccuracy
        if let c = circle, c.degraded == degraded, abs(c.radius - loc.horizontalAccuracy) < 1,
           MKMapPoint(c.coordinate).distance(to: MKMapPoint(loc.coordinate)) < 1 { return }
        if let circle { mv.removeOverlay(circle) }
        let c = AccuracyCircle(center: loc.coordinate, radius: loc.horizontalAccuracy)
        c.degraded = degraded
        mv.addOverlay(c, level: .aboveLabels)
        circle = c
    }

    private func applyLine(from a: CLLocationCoordinate2D?, to b: CLLocationCoordinate2D?, on mv: MKMapView) {
        guard let a, let b else {
            if let line { mv.removeOverlay(line); self.line = nil }
            return
        }
        if let l = line, l.pointCount == 2 {
            let p = l.points()
            if p[0].distance(to: MKMapPoint(a)) < 1, p[1].distance(to: MKMapPoint(b)) < 1 { return }
        }
        if let line { mv.removeOverlay(line) }
        var coords = [a, b]
        let l = BorderDistanceLine(coordinates: &coords, count: 2)
        l.title = L("Yasak alan sınırına çizgi")
        mv.addOverlay(l, level: .aboveLabels)
        line = l
    }

    /// Bu sınıfın katmanları için çizici; başka katmanlar için nil.
    static func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        switch overlay {
        case let c as AccuracyCircle:
            let r = MKCircleRenderer(circle: c)
            let color: UIColor = c.degraded ? .systemOrange : .systemBlue
            r.fillColor = color.withAlphaComponent(0.15)
            r.strokeColor = color.withAlphaComponent(0.5)
            r.lineWidth = 1
            return r
        case let l as BorderDistanceLine:
            let r = MKPolylineRenderer(polyline: l)
            r.strokeColor = UIColor.systemRed.withAlphaComponent(0.9)
            r.lineWidth = 2
            r.lineDashPattern = [6, 5]
            r.lineCap = .round
            return r
        default:
            return nil
        }
    }
}
