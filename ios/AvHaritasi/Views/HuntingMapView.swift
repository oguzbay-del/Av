import MapKit
import SwiftUI

enum BaseMapStyle: String, CaseIterable, Identifiable {
    case standard, hybrid, satellite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "Standart"
        case .hybrid: return "Uydu + yol"
        case .satellite: return "Uydu"
        }
    }
    var mapType: MKMapType {
        switch self {
        case .standard: return .standard
        case .hybrid: return .hybrid
        case .satellite: return .satellite
        }
    }
}

/// Apple haritası + üzerinde resmi avlak haritası katmanı + kullanıcı konumu.
struct HuntingMapView: UIViewRepresentable {
    let map: HuntingMap
    @Binding var followUser: Bool
    @Binding var inspectedCoordinate: CLLocationCoordinate2D?
    var overlayOpacity: Double
    var baseStyle: BaseMapStyle

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.showsUserLocation = true
        mv.showsCompass = true
        mv.showsScale = true
        mv.pointOfInterestFilter = .excludingAll
        mv.mapType = baseStyle.mapType

        let overlay = PackTileOverlay(pack: map.tilePack)
        mv.addOverlay(overlay, level: .aboveLabels)

        let b = map.meta.bounds
        let region = MKCoordinateRegion(center: map.center,
                                        span: MKCoordinateSpan(latitudeDelta: (b.north - b.south) * 0.6,
                                                               longitudeDelta: (b.east - b.west) * 0.6))
        mv.setRegion(region, animated: false)

        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.longPress(_:)))
        mv.addGestureRecognizer(press)
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        context.coordinator.parent = self
        if mv.mapType != baseStyle.mapType { mv.mapType = baseStyle.mapType }

        if let r = context.coordinator.renderer, abs(Double(r.alpha) - overlayOpacity) > 0.001 {
            r.alpha = CGFloat(overlayOpacity)
            r.setNeedsDisplay()
        }

        if followUser, mv.userTrackingMode == .none {
            mv.setUserTrackingMode(.follow, animated: true)
        } else if !followUser, mv.userTrackingMode != .none {
            mv.setUserTrackingMode(.none, animated: true)
        }

        context.coordinator.syncPin(on: mv, to: inspectedCoordinate)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: HuntingMapView
        var renderer: MKTileOverlayRenderer?
        private var pin: MKPointAnnotation?

        init(_ parent: HuntingMapView) { self.parent = parent }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tiles)
                r.alpha = CGFloat(parent.overlayOpacity)
                renderer = r
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            let following = mode != .none
            if following != parent.followUser {
                DispatchQueue.main.async { self.parent.followUser = following }
            }
        }

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let mv = g.view as? MKMapView else { return }
            let c = mv.convert(g.location(in: mv), toCoordinateFrom: mv)
            parent.inspectedCoordinate = c
        }

        func syncPin(on mv: MKMapView, to c: CLLocationCoordinate2D?) {
            guard let c else {
                if let pin { mv.removeAnnotation(pin); self.pin = nil }
                return
            }
            if let pin {
                if pin.coordinate.latitude != c.latitude || pin.coordinate.longitude != c.longitude {
                    pin.coordinate = c
                }
            } else {
                let p = MKPointAnnotation()
                p.coordinate = c
                p.title = "Seçilen nokta"
                mv.addAnnotation(p)
                pin = p
            }
        }
    }
}
