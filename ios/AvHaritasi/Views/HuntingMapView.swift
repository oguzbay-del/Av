import MapKit
import SwiftUI

/// MAK 2026-27 değişikliği gibi ek alanlar için çokgen.
/// Haritayı bir noktaya götürme isteği (arama sonucu vb.).
struct MapFocus: Equatable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    var span: Double = 3_000
    /// Verilirse bu alan ekrana sığdırılır (ör. avlağın tamamı).
    var rect: MKMapRect? = nil
    static func == (a: MapFocus, b: MapFocus) -> Bool { a.id == b.id }
}

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

/// Rüzgâr altı koku konisi.
final class ScentConePolygon: MKPolygon {}

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
    var scentCone: [CLLocationCoordinate2D]? = nil
    var zoneShapes: [ZoneShapes] = []
    var showZones = true
    var showOfficial = false
    var focus: MapFocus? = nil
    /// Verilirse (ve konum takip ediliyorsa) harita telefonun baktığı yöne döner.
    var heading: Double? = nil
    /// Vurgulanan avlak (ad + çokgenler).
    var highlightName: String? = nil
    var highlightPolygons: [MKPolygon] = []
    /// Çevrimdışı paketler değişince artar (indirme/silme); çevrimdışı altlık yeniden açılır.
    var offlineRevision = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.showsUserLocation = true
        mv.showsCompass = true
        mv.showsScale = true
        mv.pointOfInterestFilter = .excludingAll
        // Bölgeler vektör olduğu için yakın ölçek de net; yine de sınırlar ±birkaç yüz m
        // olduğundan sokak düzeyine inmeye gerek yok.
        mv.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 400)

        context.coordinator.applyBase(baseLayer, revision: offlineRevision, on: mv)
        context.coordinator.applyLayers(self, on: mv)
        // Ek alanlar (Adalar vb.) yer adlarının altında, bölgelerin üstünde
        for o in regs?.overrides ?? [] {
            var coords = o.coordinates
            let p = ZonePolygon(coordinates: &coords, count: coords.count)
            p.status = o.status
            p.title = o.name
            mv.addOverlay(p, level: .aboveRoads)
        }

        let b = map.meta.bounds
        mv.setRegion(MKCoordinateRegion(center: map.center,
                                        span: MKCoordinateSpan(latitudeDelta: (b.north - b.south) * 0.6,
                                                               longitudeDelta: (b.east - b.west) * 0.6)),
                     animated: false)

        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        mv.addGestureRecognizer(press)
        // Kullanıcı haritayı kaydırınca takibi bırak
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userPanned(_:)))
        pan.delegate = context.coordinator
        mv.addGestureRecognizer(pan)
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        let co = context.coordinator
        co.parent = self
        co.applyBase(baseLayer, revision: offlineRevision, on: mv)
        co.applyLayers(self, on: mv)
        co.applyBuffers(showBuffers, on: mv)
        co.applyScentCone(scentCone, on: mv)
        co.applyHighlight(highlightName, highlightPolygons, on: mv)

        if let r = co.officialRenderer, abs(Double(r.alpha) - overlayOpacity) > 0.001 {
            r.alpha = CGFloat(overlayOpacity)
            r.setNeedsDisplay()
        }
        // MapKit'in takip modu (userTrackingMode) en yakın ölçeğe yakınlaşır; 1:490.000 harita
        // orada pikselleşir. Bu yüzden takip elle yapılır: yakınlaşma korunur, yalnızca merkez kayar.
        if followUser, !co.wasFollowing, co.didInitialZoom, let c = mv.userLocation.location?.coordinate {
            mv.setCenter(c, animated: true)
        }
        co.wasFollowing = followUser
        co.syncPin(on: mv, to: inspectedCoordinate)
        if followUser, let h = heading, co.didInitialZoom,
           abs(((h - mv.camera.heading + 540).truncatingRemainder(dividingBy: 360)) - 180) > 4 {
            let cam = mv.camera.copy() as! MKMapCamera
            cam.heading = h
            mv.setCamera(cam, animated: true)
        } else if heading == nil, co.rotatedByHeading, mv.camera.heading != 0 {
            let cam = mv.camera.copy() as! MKMapCamera
            cam.heading = 0
            mv.setCamera(cam, animated: true)
        }
        co.rotatedByHeading = heading != nil
        if let f = focus, f.id != co.lastFocus {
            co.lastFocus = f.id
            if let r = f.rect {
                mv.setVisibleMapRect(r, edgePadding: UIEdgeInsets(top: 180, left: 30, bottom: 200, right: 80), animated: true)
            } else {
                mv.setRegion(MKCoordinateRegion(center: f.coordinate, latitudinalMeters: f.span, longitudinalMeters: f.span),
                             animated: true)
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: HuntingMapView
        var officialRenderer: MKTileOverlayRenderer?
        private var baseOverlay: MKTileOverlay?
        private var currentBase: BaseLayer?
        private var currentRevision = 0
        private var bufferOverlays: [MKOverlay] = []
        private var pin: MKPointAnnotation?
        private var cone: ScentConePolygon?
        private var coneKey: [Double] = []
        var didInitialZoom = false
        var wasFollowing = true
        var lastFocus: UUID?
        var rotatedByHeading = false
        private var highlight: AvlakHighlight?
        private var officialOverlay: PackTileOverlay?
        private var zoneOverlays: [ZoneShapes] = []

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let loc = userLocation.location, loc.horizontalAccuracy >= 0 else { return }
            if !didInitialZoom {
                didInitialZoom = true
                mapView.setRegion(MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 6_000, longitudinalMeters: 6_000),
                                  animated: false)
            } else if parent.followUser {
                mapView.setCenter(loc.coordinate, animated: true)
            }
        }

        @objc func userPanned(_ g: UIPanGestureRecognizer) {
            guard g.state == .began, parent.followUser else { return }
            DispatchQueue.main.async { self.parent.followUser = false }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        init(_ parent: HuntingMapView) { self.parent = parent }

        func applyBase(_ layer: BaseLayer, revision: Int, on mv: MKMapView) {
            guard layer != currentBase || (layer == .offlineTopo && revision != currentRevision) else { return }
            currentBase = layer
            currentRevision = revision
            if let old = baseOverlay { mv.removeOverlay(old); baseOverlay = nil }
            mv.preferredConfiguration = layer.configuration
            let overlay: MKTileOverlay?
            if layer == .offlineTopo {
                overlay = OfflineTopoOverlay()
            } else if layer.template != nil {
                overlay = CachingTileOverlay(layer: layer)
            } else {
                overlay = nil
            }
            if let overlay {
                mv.insertOverlay(overlay, at: 0, level: .aboveRoads)
                baseOverlay = overlay
            }
        }

        /// Vektör bölgeler yer adlarının ALTINDA çizilir (köy, yol adları okunur kalır);
        /// taranmış resmi harita isteğe bağlı olarak en üstte.
        func applyLayers(_ p: HuntingMapView, on mv: MKMapView) {
            if p.showZones, zoneOverlays.isEmpty, !p.zoneShapes.isEmpty {
                zoneOverlays = p.zoneShapes
                let index = baseOverlay == nil ? 0 : 1
                for (i, z) in zoneOverlays.enumerated() {
                    mv.insertOverlay(z, at: index + i, level: .aboveRoads)
                }
            } else if !p.showZones, !zoneOverlays.isEmpty {
                mv.removeOverlays(zoneOverlays)
                zoneOverlays = []
            }
            if p.showOfficial, officialOverlay == nil {
                let o = PackTileOverlay(pack: p.map.tilePack)
                mv.addOverlay(o, level: .aboveLabels)
                officialOverlay = o
            } else if !p.showOfficial, let o = officialOverlay {
                mv.removeOverlay(o)
                officialOverlay = nil
                officialRenderer = nil
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

        func applyHighlight(_ name: String?, _ polygons: [MKPolygon], on mv: MKMapView) {
            guard name != highlight?.name || (name != nil && highlight == nil) else { return }
            if let h = highlight { mv.removeOverlay(h); highlight = nil }
            guard let name, !polygons.isEmpty else { return }
            let h = AvlakHighlight(polygons)
            h.name = name
            mv.addOverlay(h, level: .aboveRoads)
            highlight = h
        }

        func applyScentCone(_ coords: [CLLocationCoordinate2D]?, on mv: MKMapView) {
            let key = (coords ?? []).flatMap { [($0.latitude * 1e5).rounded(), ($0.longitude * 1e5).rounded()] }
            guard key != coneKey else { return }
            coneKey = key
            if let cone { mv.removeOverlay(cone); self.cone = nil }
            guard var c = coords, c.count > 2 else { return }
            let p = ScentConePolygon(coordinates: &c, count: c.count)
            mv.addOverlay(p, level: .aboveLabels)
            cone = p
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            switch overlay {
            case let o as CachingTileOverlay:
                return MKTileOverlayRenderer(tileOverlay: o)
            case let o as OfflineTopoOverlay:
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
            case let h as AvlakHighlight:
                let r = MKMultiPolygonRenderer(multiPolygon: h)
                r.fillColor = UIColor.systemBlue.withAlphaComponent(0.10)
                r.strokeColor = UIColor.systemBlue
                r.lineWidth = 4
                r.lineJoin = .round
                return r
            case let z as ZoneShapes:
                let r = MKMultiPolygonRenderer(multiPolygon: z)
                let c = z.zone.displayColor
                r.fillColor = c.withAlphaComponent(z.zone.fillAlpha)
                r.strokeColor = c.withAlphaComponent(z.zone.status == .izinli ? 0.55 : 0.95)
                r.lineWidth = z.zone.status == .izinli ? 1 : 2
                r.lineJoin = .round
                if z.zone.status == .dikkat { r.lineDashPattern = [5, 3] }
                return r
            case let p as ScentConePolygon:
                let r = MKPolygonRenderer(polygon: p)
                r.fillColor = UIColor.systemPurple.withAlphaComponent(0.18)
                r.strokeColor = UIColor.systemPurple.withAlphaComponent(0.8)
                r.lineWidth = 1.5
                return r
            case let m as BufferCircles:
                let r = MKMultiPolygonRenderer(multiPolygon: m)
                r.fillColor = UIColor.systemRed.withAlphaComponent(0.22)
                return r
            default:
                return MKOverlayRenderer(overlay: overlay)
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
                p.title = L("Seçilen nokta")
                mv.addAnnotation(p)
                pin = p
            }
        }
    }
}
