import Foundation
import MapKit

public enum PlaceNameResolutionError: Error, Equatable, Sendable {
    /// MapKit rate-limited this app; no request is sent before `until`.
    case throttled(until: Date)
    /// Offline or a MapKit server failure; retry later.
    case transient(String)
}

/// Names a recorded coordinate through MapKit reverse geocoding, in the
/// reading language. Requests run one at a time, at least
/// `minimumRequestInterval` apart, and repeat coordinates hit a cache.
///
/// A landmark is kept only when MapKit identifies one: either the
/// reverse-geocoded name is not part of the street address (Hase-dera,
/// "Kew Gardens - Palm House"), or a point-of-interest search
/// near the coordinate returns a place with exactly that name (Serengeti
/// National Park, Central Park). Street addresses are never shown.
public actor PlaceNameResolver {
    public static let shared = PlaceNameResolver()

    static let minimumRequestInterval: Duration = .seconds(1)
    static let throttlePause: TimeInterval = 120
    static let cacheLimit = 1_024
    static let landmarkSearchSpanMeters: CLLocationDistance = 20_000

    private var cache: [String: AttachmentCaptureMetadata.Place?] = [:]
    private var cacheOrder: [String] = []
    private var lastRequest: ContinuousClock.Instant?
    private var pausedUntil: Date?

    public init() {}

    /// The place at `coordinate`, `nil` when MapKit has nothing there.
    public func place(
        for coordinate: AttachmentCaptureMetadata.Coordinate,
        languageIdentifier: String
    ) async throws -> AttachmentCaptureMetadata.Place? {
        let key = String(format: "%.4f,%.4f|%@", coordinate.latitude, coordinate.longitude, languageIdentifier)
        if let cached = cache[key] { return cached }
        if let pausedUntil, pausedUntil > Date() { throw PlaceNameResolutionError.throttled(until: pausedUntil) }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let locale = Locale(identifier: languageIdentifier)
        guard let item = try await reverseGeocode(location, locale: locale) else {
            remember(nil, for: key)
            return nil
        }
        let representations = item.addressRepresentations
        let locality = Self.nonEmpty(representations?.cityWithContext(.full))
            ?? Self.nonEmpty(representations?.cityName)
        let country = Self.nonEmpty(representations?.regionName)
        let landmark = try await landmarkName(
            item: item,
            location: location,
            locale: locale,
            hasLocality: locality != nil || country != nil
        )
        let place = AttachmentCaptureMetadata.Place(
            landmark: landmark,
            locality: locality,
            country: country,
            languageIdentifier: languageIdentifier,
            timeZoneIdentifier: item.timeZone?.identifier
        )
        let resolved: AttachmentCaptureMetadata.Place? = place.displayName == nil ? nil : place
        remember(resolved, for: key)
        return resolved
    }

    private func landmarkName(
        item: MKMapItem,
        location: CLLocation,
        locale: Locale,
        hasLocality: Bool
    ) async throws -> String? {
        guard let name = Self.nonEmpty(item.name) else { return nil }
        let folded = AttachmentCaptureMetadata.Place.folded(name)
        let shortAddress = item.address?.shortAddress ?? item.address?.fullAddress ?? ""
        if !AttachmentCaptureMetadata.Place.folded(shortAddress).contains(folded) {
            return name
        }
        // Open water and wilderness have no address beyond the name itself.
        if !hasLocality { return name }
        // A name that is part of the address and carries a number is a street
        // address ("1200 Harbor Rd", "本町3丁目4", "12345"); skip the
        // confirming search so a home address costs one MapKit request.
        if name.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) { return nil }

        // The name doubles as the address. Point-of-interest search answers
        // in the system language, so compare against the system-language name.
        let systemName: String
        if locale.language.languageCode == Locale.current.language.languageCode {
            systemName = name
        } else {
            guard let systemItem = try await reverseGeocode(location, locale: nil),
                  let resolved = Self.nonEmpty(systemItem.name) else {
                return nil
            }
            systemName = resolved
        }
        return try await isNamedPointOfInterest(systemName, near: location) ? name : nil
    }

    private func isNamedPointOfInterest(_ name: String, near location: CLLocation) async throws -> Bool {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: Self.landmarkSearchSpanMeters,
            longitudinalMeters: Self.landmarkSearchSpanMeters
        )
        request.resultTypes = [.pointOfInterest, .physicalFeature]
        let target = AttachmentCaptureMetadata.Place.folded(name)
        do {
            try await pace()
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.contains {
                $0.name.map(AttachmentCaptureMetadata.Place.folded) == target
            }
        } catch {
            try absorbNotFound(error)
            return false
        }
    }

    private func reverseGeocode(_ location: CLLocation, locale: Locale?) async throws -> MKMapItem? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = locale
        do {
            try await pace()
            return try await request.mapItems.first
        } catch {
            try absorbNotFound(error)
            return nil
        }
    }

    /// Returns normally only for MapKit's "nothing here"; every other
    /// failure is rethrown as cancellation, throttling or a transient error.
    private func absorbNotFound(_ error: Error) throws {
        if error is CancellationError { throw error }
        let nsError = error as NSError
        if nsError.domain == MKErrorDomain {
            switch MKError.Code(rawValue: UInt(nsError.code)) {
            case .placemarkNotFound:
                return
            case .loadingThrottled:
                let until = Date().addingTimeInterval(Self.throttlePause)
                pausedUntil = until
                throw PlaceNameResolutionError.throttled(until: until)
            default:
                throw PlaceNameResolutionError.transient("MapKit error \(nsError.code)")
            }
        }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            throw CancellationError()
        }
        throw PlaceNameResolutionError.transient(nsError.localizedDescription)
    }

    /// Reserves the next request slot before suspending, so concurrent
    /// callers re-entering the actor queue up one interval apart.
    private func pace() async throws {
        let clock = ContinuousClock()
        let now = clock.now
        let slot = lastRequest.map { max(now, $0 + Self.minimumRequestInterval) } ?? now
        lastRequest = slot
        if slot > now {
            try await clock.sleep(until: slot)
        }
    }

    private func remember(_ place: AttachmentCaptureMetadata.Place?, for key: String) {
        if cache.updateValue(place, forKey: key) == nil {
            cacheOrder.append(key)
        }
        if cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
