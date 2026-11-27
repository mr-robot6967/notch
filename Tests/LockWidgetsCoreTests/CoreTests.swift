import Foundation
import CoreGraphics
import Testing
@testable import LockWidgetsCore

@Test func parsesAirPodsAndMouseFromSystemProfiler() throws {
    let json = """
    {"SPBluetoothDataType":[{"controller_properties":{},
      "device_connected":[
        {"My AirPods Pro":{"device_minorType":"Headphones","device_batteryLevelLeft":"80%","device_batteryLevelRight":"75%","device_batteryLevelCase":"40%"}},
        {"MX Master":{"device_minorType":"Mouse","device_batteryLevelMain":"55 %"}},
        {"No Battery Speaker":{"device_minorType":"Speaker"}}
      ],
      "device_not_connected":[{"Old Mouse":{"device_minorType":"Mouse","device_batteryLevelMain":"10%"}}]
    }]}
    """
    let devices = BluetoothParser.parse(Data(json.utf8))
    #expect(devices.count == 4)
    let left = try #require(devices.first { $0.component == "L" })
    #expect(left.level == 80)
    #expect(left.kind == .earbudLeft)
    #expect(devices.contains { $0.component == "Case" && $0.level == 40 && $0.kind == .earbudCase })
    let mouse = try #require(devices.first { $0.name == "MX Master" })
    #expect(mouse.level == 55 && mouse.kind == .mouse)
    #expect(!devices.contains { $0.name == "Old Mouse" })
}

@Test func garbageInputGivesNoDevices() {
    #expect(BluetoothParser.parse(Data("not json".utf8)).isEmpty)
    #expect(BluetoothParser.parse(Data("{}".utf8)).isEmpty)
}

@Test func mergePrefersHIDAndDedupesByName() {
    let hid = [DeviceBattery(name: "Magic Mouse", kind: .mouse, level: 60, isCharging: true)]
    let bt = [
        DeviceBattery(name: "magic mouse", kind: .mouse, level: 61),
        DeviceBattery(name: "AirPods", kind: .earbudLeft, level: 90, component: "L"),
    ]
    let merged = PeripheralMerge.merge(hid: hid, bluetooth: bt)
    #expect(merged.count == 2)
    #expect(merged.first { $0.kind == .mouse }?.isCharging == true)
}

@Test func levelIsClampedAndIdsAreStable() {
    let d = DeviceBattery(name: "Pods", kind: .earbudCase, level: 140, component: "Case")
    #expect(d.level == 100)
    #expect(d.id == "Pods#Case")
    #expect(d.displayName == "Pods (Case)")
}

@Test func decodesOpenMeteoForecast() throws {
    let json = """
    {"latitude":51.5,"longitude":-0.12,"timezone":"Europe/London",
     "current":{"time":"2026-11-27T10:00","temperature_2m":8.4,"apparent_temperature":5.1,"weather_code":61,"is_day":1,"relative_humidity_2m":87,"wind_speed_10m":14.2},
     "daily":{"time":["2026-11-27","2026-11-28","2026-11-29"],"weather_code":[61,3,0],"temperature_2m_max":[9.9,10.5,7.0],"temperature_2m_min":[4.1,5.0,1.2]}}
    """
    let w = try OpenMeteo.decodeForecast(Data(json.utf8), locationName: "London", unit: .celsius)
    #expect(w.temperature == 8.4)
    #expect(w.condition == "Rain")
    #expect(w.symbol == "cloud.rain.fill")
    #expect(w.high == 9.9 && w.low == 4.1)
    #expect(w.daily.count == 3)
    #expect(w.daily[2].code == 0)
}

@Test func decodesGeocodeAndHandlesNoResults() throws {
    let hit = #"{"results":[{"name":"Pune","latitude":18.52,"longitude":73.86,"country":"India"}]}"#
    let place = try #require(try OpenMeteo.decodeGeocode(Data(hit.utf8)))
    #expect(place.name == "Pune" && place.country == "India")
    #expect(try OpenMeteo.decodeGeocode(Data(#"{"generationtime_ms":0.5}"#.utf8)) == nil)
}

@Test func urlsAreWellFormed() throws {
    let url = OpenMeteo.forecastURL(latitude: 18.5204, longitude: 73.8567, unit: .fahrenheit)
    let s = url.absoluteString
    #expect(s.contains("latitude=18.520"))
    #expect(s.contains("temperature_unit=fahrenheit"))
    #expect(OpenMeteo.geocodeURL(city: "   ") == nil)
    let g = try #require(OpenMeteo.geocodeURL(city: "San José"))
    #expect(g.absoluteString.contains("name=San%20Jos"))
}

@Test func nightAndDaySymbolsDiffer() {
    #expect(WeatherCode.symbol(0, isDay: true) == "sun.max.fill")
    #expect(WeatherCode.symbol(0, isDay: false) == "moon.stars.fill")
    #expect(WeatherCode.describe(12345) == "—")
}

@Test func normalizeKeepsOrderAndAddsMissing() {
    let saved = [
        WidgetEntry(kind: .peripherals, enabled: true, size: .expanded),
        WidgetEntry(kind: .peripherals, enabled: false, size: .compact),
        WidgetEntry(kind: .weather, enabled: false, size: .compact),
    ]
    let n = WidgetEntry.normalized(saved)
    #expect(n.count == WidgetKind.allCases.count)
    #expect(n[0].kind == .peripherals && n[0].size == .expanded)
    #expect(n[1].kind == .weather)
}

@Test func batteryRampMatchesReference() {
    #expect(BatteryLook.status(for: 19) == .low)
    #expect(BatteryLook.status(for: 20) == .medium)
    #expect(BatteryLook.status(for: 49) == .medium)
    #expect(BatteryLook.status(for: 50) == .good)
    #expect(BatteryLook.symbol(for: 80, charging: false) == "battery.75percent")
    #expect(BatteryLook.symbol(for: 5, charging: false) == "battery.0percent")
    #expect(BatteryLook.symbol(for: 5, charging: true) == "bolt.fill")
}

@Test func airQualityDecodesAndCategorises() {
    let json = #"{"current":{"time":"2026-11-27T12:00","us_aqi":42.4}}"#
    #expect(OpenMeteo.decodeAirQuality(Data(json.utf8)) == 42)
    #expect(OpenMeteo.decodeAirQuality(Data("{}".utf8)) == nil)
    #expect(AirQualityLevel(aqi: 42) == .good)
    #expect(AirQualityLevel(aqi: 120) == .sensitive)
    #expect(AirQualityLevel(aqi: 400) == .hazardous)
}

@Test func temperatureFractionClamps() {
    #expect(temperatureFraction(current: 5, low: 0, high: 10) == 0.5)
    #expect(temperatureFraction(current: -5, low: 0, high: 10) == 0)
    #expect(temperatureFraction(current: 3, low: 3, high: 3) == 0.5)
}

@Test func placementKeepsBoxOnScreen() {
    let screen = CGSize(width: 1000, height: 800)
    let box = CGSize(width: 200, height: 100)
    #expect(ScreenPlacement(x: 0.5, y: 0.5).origin(for: box, in: screen) == CGPoint(x: 400, y: 350))
    #expect(ScreenPlacement(x: 0.0, y: 1.0).origin(for: box, in: screen) == CGPoint(x: 0, y: 700))
    #expect(ScreenPlacement(x: -3, y: 9).clamped() == ScreenPlacement(x: 0.02, y: 0.98))
}
