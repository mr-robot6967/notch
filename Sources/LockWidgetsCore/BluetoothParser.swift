import Foundation

/// Parses `system_profiler SPBluetoothDataType -json` output into battery readings.
/// This is where AirPods / Beats / many third-party headsets report their battery.
public enum BluetoothParser {
    private static let fields: [(key: String, component: String?, kind: DeviceKind?)] = [
        ("device_batteryLevelMain", nil, nil),
        ("device_batteryLevel", nil, nil),
        ("device_batteryLevelLeft", "L", .earbudLeft),
        ("device_batteryLevelRight", "R", .earbudRight),
        ("device_batteryLevelCase", "Case", .earbudCase),
    ]

    public static func parse(_ data: Data) -> [DeviceBattery] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var out: [DeviceBattery] = []
        for controller in controllers {
            guard let connected = controller["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let minor = info["device_minorType"] as? String ?? ""
                    let baseKind = DeviceKind.guess(from: minor.isEmpty ? name : minor)
                    for field in fields {
                        guard let raw = info[field.key], let level = percent(raw) else { continue }
                        out.append(DeviceBattery(
                            name: name,
                            kind: field.kind ?? baseKind,
                            level: level,
                            component: field.component
                        ))
                    }
                }
            }
        }
        return out
    }

    /// Accepts "85%", "85 %", "85" or a number.
    static func percent(_ raw: Any) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? Double { return Int(n) }
        guard let s = raw as? String else { return nil }
        return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }
}
