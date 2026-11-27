import Foundation

public enum TemperatureUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case celsius, fahrenheit
    public var id: String { rawValue }
    public var symbol: String { self == .celsius ? "°C" : "°F" }
}

public struct DailyForecast: Codable, Equatable, Identifiable, Sendable {
    public var date: Date
    public var high: Double
    public var low: Double
    public var code: Int
    public var id: Date { date }
}

public struct WeatherSnapshot: Codable, Equatable, Sendable {
    public var locationName: String
    public var temperature: Double
    public var apparentTemperature: Double
    public var code: Int
    public var isDay: Bool
    public var humidity: Double
    public var windSpeed: Double
    public var high: Double
    public var low: Double
    public var daily: [DailyForecast]
    public var unit: TemperatureUnit
    public var fetchedAt: Date
    /// US AQI (0-500), nil when the air-quality service didn't answer.
    public var airQuality: Int? = nil

    public var condition: String { WeatherCode.describe(code) }
    public var symbol: String { WeatherCode.symbol(code, isDay: isDay) }
}

public struct GeoPlace: Codable, Equatable, Sendable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var country: String?
}

public enum WeatherError: Error, LocalizedError {
    case badResponse
    case cityNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse: return "Weather service returned an unexpected response"
        case .cityNotFound(let city): return "Couldn't find “\(city)”"
        }
    }
}

/// Open-Meteo: free, no API key. https://open-meteo.com
public enum OpenMeteo {
    public static func forecastURL(latitude: Double, longitude: Double, unit: TemperatureUnit) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,relative_humidity_2m,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "5"),
            URLQueryItem(name: "temperature_unit", value: unit.rawValue),
        ]
        return c.url!
    }

    public static func airQualityURL(latitude: Double, longitude: Double) -> URL {
        var c = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "current", value: "us_aqi"),
        ]
        return c.url!
    }

    private struct AirQualityResponse: Decodable {
        struct Current: Decodable { let us_aqi: Double? }
        let current: Current?
    }

    public static func decodeAirQuality(_ data: Data) -> Int? {
        guard let r = try? JSONDecoder().decode(AirQualityResponse.self, from: data),
              let v = r.current?.us_aqi else { return nil }
        return Int(v.rounded())
    }

    public static func geocodeURL(city: String) -> URL? {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [
            URLQueryItem(name: "name", value: trimmed),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return c.url
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let weather_code: Int
            let is_day: Int
            let relative_humidity_2m: Double
            let wind_speed_10m: Double
        }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let timezone: String?
        let current: Current
        let daily: Daily
    }

    public static func decodeForecast(_ data: Data, locationName: String, unit: TemperatureUnit, now: Date = Date()) throws -> WeatherSnapshot {
        let r = try JSONDecoder().decode(ForecastResponse.self, from: data)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = r.timezone.flatMap(TimeZone.init(identifier:)) ?? .current

        let count = min(r.daily.time.count, r.daily.weather_code.count, r.daily.temperature_2m_max.count, r.daily.temperature_2m_min.count)
        var days: [DailyForecast] = []
        for i in 0..<count {
            guard let date = fmt.date(from: r.daily.time[i]) else { continue }
            days.append(DailyForecast(date: date, high: r.daily.temperature_2m_max[i], low: r.daily.temperature_2m_min[i], code: r.daily.weather_code[i]))
        }
        guard let today = days.first else { throw WeatherError.badResponse }

        return WeatherSnapshot(
            locationName: locationName,
            temperature: r.current.temperature_2m,
            apparentTemperature: r.current.apparent_temperature,
            code: r.current.weather_code,
            isDay: r.current.is_day == 1,
            humidity: r.current.relative_humidity_2m,
            windSpeed: r.current.wind_speed_10m,
            high: today.high,
            low: today.low,
            daily: days,
            unit: unit,
            fetchedAt: now
        )
    }

    private struct GeocodeResponse: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
        }
        let results: [Result]?
    }

    public static func decodeGeocode(_ data: Data) throws -> GeoPlace? {
        let r = try JSONDecoder().decode(GeocodeResponse.self, from: data)
        guard let first = r.results?.first else { return nil }
        return GeoPlace(name: first.name, latitude: first.latitude, longitude: first.longitude, country: first.country)
    }
}

/// WMO weather interpretation codes used by Open-Meteo.
public enum WeatherCode {
    public static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly Clear"
        case 2: return "Partly Cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing Drizzle"
        case 61, 63: return "Rain"
        case 65: return "Heavy Rain"
        case 66, 67: return "Freezing Rain"
        case 71, 73, 75: return "Snow"
        case 77: return "Snow Grains"
        case 80, 81: return "Showers"
        case 82: return "Heavy Showers"
        case 85, 86: return "Snow Showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm, Hail"
        default: return "—"
        }
    }

    public static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0, 1: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63, 80, 81: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 85, 86: return "cloud.snow.fill"
        case 77: return "snowflake"
        case 95: return "cloud.bolt.fill"
        case 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

/// US AQI categories.
public enum AirQualityLevel: Equatable, Sendable {
    case good, moderate, sensitive, unhealthy, veryUnhealthy, hazardous

    public init(aqi: Int) {
        switch aqi {
        case ..<51: self = .good
        case ..<101: self = .moderate
        case ..<151: self = .sensitive
        case ..<201: self = .unhealthy
        case ..<301: self = .veryUnhealthy
        default: self = .hazardous
        }
    }

    public var title: String {
        switch self {
        case .good: return "Good"
        case .moderate: return "Moderate"
        case .sensitive: return "Sensitive"
        case .unhealthy: return "Unhealthy"
        case .veryUnhealthy: return "Very Unhealthy"
        case .hazardous: return "Hazardous"
        }
    }

    /// sRGB components for the gauge tint.
    public var rgb: (Double, Double, Double) {
        switch self {
        case .good: return (0.20, 0.79, 0.39)
        case .moderate: return (0.97, 0.82, 0.30)
        case .sensitive: return (0.98, 0.57, 0.24)
        case .unhealthy: return (0.91, 0.29, 0.25)
        case .veryUnhealthy: return (0.65, 0.32, 0.86)
        case .hazardous: return (0.50, 0.13, 0.28)
        }
    }
}

/// Where the current temperature sits between today's low and high (0...1).
public func temperatureFraction(current: Double, low: Double, high: Double) -> Double {
    guard high > low else { return 0.5 }
    return min(1, max(0, (current - low) / (high - low)))
}
