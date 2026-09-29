import Foundation

/// Small synchronous writes on the Bluetooth/main queue. Diagnostic logs contain
/// no credentials or measurement values. Separate measurement storage uses the
/// same protected, backup-excluded directory, usable after the first unlock.
final class ProbeStorage {
    let directory: URL
    private let configurationURL: URL
    let eventsURL: URL
    private let fm = FileManager.default

    init() throws {
        directory = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true)
            .appendingPathComponent("S400WakeProbe", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        configurationURL = directory.appendingPathComponent("configuration.json")
        eventsURL = directory.appendingPathComponent("events.jsonl")
    }

    func load() throws -> ProbeConfiguration {
        guard fm.fileExists(atPath: configurationURL.path) else { return ProbeConfiguration() }
        // A damaged/inaccessible configuration is an error, not permission to
        // overwrite it or silently bind to a different scale.
        return try JSONDecoder().decode(ProbeConfiguration.self, from: Data(contentsOf: configurationURL))
    }

    func save(_ configuration: ProbeConfiguration) throws {
        try JSONEncoder().encode(configuration).write(to: configurationURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func append(_ event: ProbeEvent) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event)
        data.append(0x0A)
        try rotateIfNeeded()
        if !fm.fileExists(atPath: eventsURL.path) {
            try Data().write(to: eventsURL, options: [.completeFileProtectionUntilFirstUserAuthentication])
        }
        let handle = try FileHandle(forWritingTo: eventsURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func recentLines() throws -> [String] {
        guard fm.fileExists(atPath: eventsURL.path) else { return [] }
        return try String(contentsOf: eventsURL, encoding: .utf8).split(separator: "\n").suffix(60).map(String.init).reversed()
    }

    func export() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("S400-probe-\(UUID().uuidString).jsonl")
        var result = Data()
        for source in [archive(2), archive(1), eventsURL] where fm.fileExists(atPath: source.path) {
            result.append(try Data(contentsOf: source))
        }
        try result.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    private func archive(_ number: Int) -> URL {
        directory.appendingPathComponent("events.\(number).jsonl")
    }

    private func rotateIfNeeded() throws {
        guard fm.fileExists(atPath: eventsURL.path),
              let size = try fm.attributesOfItem(atPath: eventsURL.path)[.size] as? NSNumber,
              size.intValue >= 2_000_000 else { return }
        if fm.fileExists(atPath: archive(2).path) { try fm.removeItem(at: archive(2)) }
        if fm.fileExists(atPath: archive(1).path) { try fm.moveItem(at: archive(1), to: archive(2)) }
        try fm.moveItem(at: eventsURL, to: archive(1))
    }
}
