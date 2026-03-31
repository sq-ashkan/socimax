import Foundation
import CryptoKit

/// AES-GCM encrypted local storage for API keys — no Keychain dependency.
/// Keys are encrypted with a machine-specific key derived from the hardware UUID.
final class KeychainService {
    static let shared = KeychainService()

    private let storageURL: URL
    private let encryptionKey: SymmetricKey

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SociMax")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent(".keys")

        // Derive a stable encryption key from machine-specific hardware UUID
        let seed = Self.machineIdentifier()
        let hash = SHA256.hash(data: Data(seed.utf8))
        encryptionKey = SymmetricKey(data: hash)
    }

    func set(key: String, value: String) {
        var store = loadStore()
        guard let plainData = value.data(using: .utf8) else { return }

        do {
            let sealed = try AES.GCM.seal(plainData, using: encryptionKey)
            guard let combined = sealed.combined else { return }
            store[key] = combined.base64EncodedString()
            saveStore(store)
        } catch {
            FileLogger.shared.log("Encrypt failed for '\(key)': \(error)")
        }
    }

    func get(key: String) -> String? {
        let store = loadStore()
        guard let encoded = store[key],
              let combined = Data(base64Encoded: encoded) else { return nil }

        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let decrypted = try AES.GCM.open(box, using: encryptionKey)
            return String(data: decrypted, encoding: .utf8)
        } catch {
            FileLogger.shared.log("Decrypt failed for '\(key)': \(error)")
            return nil
        }
    }

    func delete(key: String) {
        var store = loadStore()
        store.removeValue(forKey: key)
        saveStore(store)
    }

    // MARK: - Private

    private func loadStore() -> [String: String] {
        guard let data = try? Data(contentsOf: storageURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private func saveStore(_ store: [String: String]) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    /// Machine-specific identifier for key derivation (hardware UUID)
    private static func machineIdentifier() -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if let range = output.range(of: "IOPlatformUUID\" = \""),
               let end = output[range.upperBound...].range(of: "\"") {
                return String(output[range.upperBound..<end.lowerBound])
            }
        } catch {}

        // Fallback
        return "socimax-\(ProcessInfo.processInfo.hostName)-fallback"
    }
}
