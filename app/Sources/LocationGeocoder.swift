import Foundation
import CoreLocation

/// Serial, cached reverse geocoder. Coordinates are rounded to 4 decimals,
/// so photos taken at the same place share one lookup.
final class LocationGeocoder {
    static let shared = LocationGeocoder()

    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]
    private var callbacks: [String: [(String?) -> Void]] = [:]
    private var pending: [(String, Double, Double)] = []
    private var active: UUID?

    func resolve(lat: Double, lon: Double, completion: @escaping (String?) -> Void) {
        let key = String(format: "%.4f,%.4f", lat, lon)
        if let cached = cache[key] {
            completion(cached)
            return
        }
        guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else {
            completion(nil)
            return
        }
        if callbacks[key] != nil { callbacks[key]?.append(completion); return }
        callbacks[key] = [completion]
        pending.append((key, lat, lon))
        drain()
    }

    private func drain() {
        guard active == nil, !pending.isEmpty else { return }
        let (key, lat, lon) = pending.removeFirst()
        let request = UUID()
        active = request
        func finish(_ name: String?) {
            guard self.active == request else { return }
            self.active = nil
            if let name = name { self.cache[key] = name }
            let waiting = self.callbacks.removeValue(forKey: key) ?? []
            waiting.forEach { $0(name) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { self.drain() }
        }

        geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)) { [weak self] placemarks, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.active == request else { return }
                let name: String? = {
                    guard let pm = placemarks?.first else { return nil }
                    var parts: [String] = []
                    for value in [pm.administrativeArea, pm.locality, pm.subLocality,
                                  pm.thoroughfare, pm.subThoroughfare] {
                        if let value = value, !value.isEmpty, parts.last != value {
                            parts.append(value)
                        }
                    }
                    let joined = parts.joined()
                    return joined.isEmpty ? pm.name : joined
                }()

                finish(name)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            guard self.active == request else { return }
            self.geocoder.cancelGeocode()
            finish(nil)
        }
    }
}
