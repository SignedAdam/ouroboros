import Foundation
import CryptoKit

public enum Paths {
    public static var home: String {
        if let override = ProcessInfo.processInfo.environment["OUROBOROS_HOME"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".ouroboros")
    }

    public static var socket: String {
        let natural = sub("ourod.sock")
        if natural.utf8.count < 100 { return natural }
        let digest = SHA256.hash(data: Data(home.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(10)
        return "/tmp/ouroboros-\(hex).sock"
    }
    public static var configFile: String { sub("config.json") }
    public static var registryFile: String { sub("projects.json") }
    public static var runsDir: String { sub("runs") }
    public static var ideasDir: String { sub("ideas") }
    public static var proposalsDir: String { sub("proposals") }
    public static var daemonLog: String { sub("ourod.log") }
    public static var pidFile: String { sub("ourod.pid") }

    public static func runDir(_ id: String) -> String {
        (runsDir as NSString).appendingPathComponent(id)
    }

    static func sub(_ name: String) -> String {
        (home as NSString).appendingPathComponent(name)
    }

    @discardableResult
    public static func ensure() -> Bool {
        let fm = FileManager.default
        for d in [home, runsDir, ideasDir, proposalsDir] {
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        return fm.fileExists(atPath: home)
    }
}

public enum Zero {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let compactEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }

    @discardableResult
    public static func writeJSON<T: Encodable>(_ value: T, to path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        do {
            try encoder.encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func readJSON<T: Decodable>(_ type: T.Type, from path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return decode(type, from: data)
    }

    public static func newID(_ prefix: String) -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let stamp = String(ms, radix: 36)
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        let tail = String((0..<4).map { _ in alphabet.randomElement()! })
        return "\(prefix)-\(stamp)-\(tail)"
    }
}
