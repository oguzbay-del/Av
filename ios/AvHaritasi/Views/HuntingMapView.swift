import MapKit
import SwiftUI

/// MAK 2026-27 değişikliği gibi ek alanlar için çokgen.
final class ZonePolygon: MKPolygon {
    var status: ZoneStatus = .yasak
}

/// 300 m yasak bandı: çizgi genişliği metre cinsinden çizilir.
final class BufferMultiPolyline: MKMultiPolyline {
    var bufferMeters: Double = 300
}

final class MeterWidthPolylineRenderer: MKMultiPolylineRenderer {
    var widthMeters: Double = 600
    override func applyStrokeProperties(to context: CGContext, atZoomScale zoomScale: MKZoomScale) {
        super.applyStrokeProperties(to: context, atZoomScale: zoomScale)
        context.setLineWidth(CGFloat(MKMapPointsPerMeterAtLatitude(41) * widthMeters))
        context.setLineCap(.round)
        context.setLineJoin(.round)
    }
}

/// Noktaların çevresindeki 300 m daireleri tek katmanda.
final class BufferCircles: MKMultiPolygon {}

/// Apple haritası / OSM altlığı + resmi avlak haritası + kural katmanları + konum.
struct HuntingMapView: UIViewRepresentable {
    let map: HuntingMap
    let features: MapFeatures?
    let regs: Regulations?
    @Binding var followUser: Bool
    @Binding var inspectedCoordinate: CLLocationCoordinate2D?
    var overlayOpacity: Double
    var baseLayer: BaseLayer
    var showBuffers: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.showsUserLocation = true
        mv.showsCompass = true
        mv.showsScale = true
        mv.pointOfInterestFilter = .excludingAll
        // Basılı harita 1:490.000; çok yakınlaşınca pikseller anlamsızlaşır.
        mv.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 1_200)

        mv.addOverlay(PackTileOverlay(pack: map.tilePack), level: .aboveLabels)
        for o in regs?.overrides ?? [] {
            var coords = o.coordinates
            let p = ZonePolygon(coordinates: &coords, count: coords.count)
            p.status = o.status
            p.title = o.name
            mv.addOverlay(p, level: .aboveLabels)
        }
        context.coordinator.applyBase(baseLayer, on: mv)

        let b = map.meta.bounds
        mv.setRegion(MKCoordinateRegion(center: map.center,
                                        span: MKCoordinateSpan(latitudeDelta: (b.north - b.south) * 0.6,
                                                               longitudeDelta: (b.east - b.west) * 0.6)),
                     animated: false)

        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        mv.addGestureRecognizer(press)
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        let co = context.coordinator
        co.parent = self
        co.applyBase(baseLayer, on: mv)
        co.applyBuffers(showBuffers, on: mv)

        if let r = co.officialRenderer, abs(Double(r.alpha) - overlayOpacity) > 0.001 {
            r.alpha = CGFloat(overlayOpacity)
            r.setNeedsDisplay()
        }
        if followUser, mv.userTrackingMode == .none {
            // İlk konumdan önce takip moduna geçilirse MapKit en yakına yakınlaşır;
            // ilk konumda 4 km'lik bölge ayarlandıktan sonra takibe geç.
            if co.didInitialZoom { mv.setUserTrackingMode(.follow, animated: true) }
        } else if !followUser, mv.userTrackingMode != .none {
            mv.setUserTrackingMode(.none, animated: true)
        }
        co.syncPin(on: mv, to: inspectedCoordinate)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: HuntingMapView
        var officialRenderer: MKTileOverlayRenderer?
        private var baseOverlay: CachingTileOverlay?
        private var currentBase: BaseLayer?
        private var bufferOverlays: [MKOverlay] = []
        private var pin: MKPointAnnotation?
        var didInitialZoom = false

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !didInitialZoom, let loc = userLocation.location, loc.horizontalAccuracy >= 0 else { return }
            didInitialZoom = true
            mapView.setRegion(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 4_000, longitudinalMeters: 4_000),
                              animated: false)
            if parent.followUser { mapView.setUserTrackingMode(.follow, animated: false) }
        }

        init(_ parent: HuntingMapView) { self.parent = parent }

        func applyBase(_ layer: BaseLayer, on mv: MKMapView) {
            guard layer != currentBase else { return }
            currentBase = layer
            if let old = baseOverlay { mv.removeOverlay(old); baseOverlay = nil }
            mv.mapType = layer.mapType
            if layer.template != nil {
                let o = CachingTileOverlay(layer: layer)
                mv.insertOverlay(o, at: 0, level: .aboveRoads)
                baseOverlay = o
            }
        }

        func applyBuffers(_ show: Bool, on mv: MKMapView) {
            if !show {
                if !bufferOverlays.isEmpty { mv.removeOverlays(bufferOverlays); bufferOverlays = [] }
                return
            }
            guard bufferOverlays.isEmpty, let f = parent.features else { return }
            let meters = parent.regs?.distanceRule("kgm")?.meters ?? 300
            let lines: [MKPolyline] = (f.roadLines["kgm"] ?? []).map { line in
                var coords = line.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
                return MKPolyline(coordinates: &coords, count: coords.count)
            }
            let roads = BufferMultiPolyline(lines)
            roads.bufferMeters = meters

            let r = parent.regs?.distanceRule("meskun")?.meters ?? 300
            let circles: [MKPolygon] = f.places.filter { $0.kind != "il" }.map { p in
                let proj = LocalProjection(p.coordinate)
                let d = proj.degrees(for: r)
                var coords = (0..<24).map { i -> CLLocationCoordinate2D in
                    let a = Double(i) / 24 * 2 * .pi
                    return CLLocationCoordinate2D(latitude: p.lat + d.lat * sin(a), longitude: p.lon + d.lon * cos(a))
                }
                return MKPolygon(coordinates: &coords, count: coords.count)
            }
            let dots = BufferCircles(circles)
            bufferOverlays = [roads, dots]
            mv.addOverlays(bufferOverlays, level: .aboveLabels)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            switch overlay {
            case let o as CachingTileOverlay:
                return MKTileOverlayRenderer(tileOverlay: o)
            case let o as MKTileOverlay:
                let r = MKTileOverlayRenderer(tileOverlay: o)
                r.alpha = CGFloat(parent.overlayOpacity)
                officialRenderer = r
                return r
            case let p as ZonePolygon:
                let r = MKPolygonRenderer(polygon: p)
                let color: UIColor = p.status == .yasak ? .systemRed : .systemOrange
                r.fillColor = color.withAlphaComponent(0.25)
                r.strokeColor = color
                r.lineWidth = 2
                r.lineDashPattern = [6, 4]
                return r
            case let m as BufferMultiPolyline:
                let r = MeterWidthPolylineRenderer(multiPolyline: m)
                r.widthMeters = m.bufferMeters * 2
                r.strokeColor = UIColor.systemRed.withAlphaComponent(0.22)
                return r
            case let m as BufferCircles:
                let r = MKMultiPolygonRenderer(multiPolygon: m)
                r.fillColor = UIColor.systemRed.withAlphaComponent(0.22)
                return r
            default:
                return MKOverlayRenderer(overlay: overlay)
            }
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            let following = mode != .none
            if following != parent.followUser {
                DispatchQueue.main.async { self.parent.followUser = following }
            }
        }

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let mv = g.view as? MKMapView else { return }
            parent.inspectedCoordinate = mv.convert(g.location(in: mv), toCoordinateFrom: mv)
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
