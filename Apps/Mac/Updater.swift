import AppKit
import CryptoKit
import Foundation
import Observation
import Security
import UsageKit

/// Checks GitHub releases for a newer Token Tracker and installs it in place.
///
/// Before swapping anything it checks that the download is signed with the same team's
/// Developer ID as the running app and passes Gatekeeper (notarized), so a tampered or
/// look-alike build is refused.
@MainActor
@Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading
        case installing
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var available: AppRelease?
    private(set) var lastChecked: Date?

    /// Called when a check finds a release, so the app can notify or auto-install.
    var onFound: ((AppRelease) -> Void)?

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private let repository = Bundle.main.object(forInfoDictionaryKey: "TTUpdateRepository") as? String
    private var schedule: Task<Void, Never>?

    /// Updates need a signed build to compare the download against.
    var isSupported: Bool { repository != nil && Self.teamIdentifier() != nil }

    func startChecking(every interval: TimeInterval = 24 * 3600) {
        schedule?.cancel()
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopChecking() {
        schedule?.cancel()
        schedule = nil
    }

    func check() async {
        guard isSupported, let repository, state != .downloading, state != .installing else { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue(UsageFetcher.appUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.isolated.send(request)
            guard response.statusCode == 200 else { throw UpdateError("GitHub returned HTTP \(response.statusCode).") }
            lastChecked = Date()
            if let release = AppRelease.parseLatest(data), AppRelease.isNewer(release.version, than: currentVersion) {
                let isNew = available?.version != release.version
                available = release
                state = .idle
                if isNew { onFound?(release) }
            } else {
                available = nil
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func install() async {
        guard let release = available else { return }
        state = .downloading
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("TokenTrackerUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }

            let zip = try await download(release.zipURL, to: work.appendingPathComponent("update.zip"))
            if let checksumURL = release.checksumURL {
                try await verifyChecksum(of: zip, against: checksumURL)
            }

            state = .installing
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
            else { throw UpdateError("The download didn't contain the app.") }

            try verifySignature(of: newApp)
            // The app quits on relaunch, so tidy up here rather than relying on `defer`.
            try replaceAndRelaunch(with: newApp, cleaningUp: work)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Steps

    private func download(_ url: URL, to destination: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func verifyChecksum(of file: URL, against url: URL) async throws {
        let (data, _) = try await URLSession.shared.data(from: url)
        let expected = String(decoding: data, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        let actual = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, expected.lowercased() == actual else {
            throw UpdateError("The download's checksum didn't match the release.")
        }
    }

    /// Same bundle ID, signed with Developer ID by the same team as this copy, and accepted by
    /// Gatekeeper (which requires Apple's notarization).
    private func verifySignature(of app: URL) throws {
        guard let team = Self.teamIdentifier(), let bundleID = Bundle.main.bundleIdentifier else {
            throw UpdateError("This copy isn't signed, so updates can't be verified.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("Couldn't read the update's signature.")
        }
        let developerID = "certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\" and \(developerID)"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement) == errSecSuccess
        else { throw UpdateError("The update isn't signed by the same developer. Not installing it.") }

        do {
            try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        } catch {
            throw UpdateError("Gatekeeper rejected the update (not notarized). Not installing it.")
        }
    }

    private func replaceAndRelaunch(with newApp: URL, cleaningUp work: URL) throws {
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw UpdateError("Can't write to \(current.deletingLastPathComponent().path). Move Token Tracker to Applications and try again.")
        }
        _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp)
        try? FileManager.default.removeItem(at: work)

        // Reopen once this process has quit.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", current.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    /// The team that signed this running copy, or nil for unsigned and ad-hoc builds.
    static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("\((tool as NSString).lastPathComponent) failed.") }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
