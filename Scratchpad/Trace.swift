import Foundation

/// Launch with `-trace YES` to print what the pad is doing to stdout, for diagnosing a device from
/// the Mac (`devicectl device process launch --console ... -trace YES`). Silent otherwise.
enum Trace {
    static let isOn = UserDefaults.standard.bool(forKey: "trace")

    static func log(_ message: @autoclosure () -> String) {
        guard isOn else { return }
        print("[pad] \(message())")
        fflush(stdout)
    }
}
