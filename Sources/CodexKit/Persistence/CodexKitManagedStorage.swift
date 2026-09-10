import Foundation

package enum CodexKitManagedStoreKind: Sendable {
    case realmMemory
    case realmRuntime
    case sqliteMemory
    case sqliteRuntime

    var adapterDirectory: String {
        switch self {
        case .realmMemory, .realmRuntime:
            "Realm"
        case .sqliteMemory, .sqliteRuntime:
            "SQLite"
        }
    }

    var filename: String {
        switch self {
        case .realmMemory:
            "memory.realm"
        case .realmRuntime:
            "runtime-state.realm"
        case .sqliteMemory:
            "memory.sqlite"
        case .sqliteRuntime:
            "runtime-state.sqlite"
        }
    }
}

package enum CodexKitManagedStorageError: Error, LocalizedError, Sendable {
    case applicationSupportDirectoryUnavailable
    case invalidStorageDirectory

    package var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            "CodexKit could not locate the application's support directory for managed storage."
        case .invalidStorageDirectory:
            "CodexKit storage requires a local directory, not a database file."
        }
    }
}

/// Derives persistence locations owned by CodexKit instead of accepting
/// host-provided database URLs. The bundle component keeps unsandboxed macOS
/// applications apart.
package struct CodexKitManagedStorageLayout: Sendable {
    package let applicationSupportDirectory: URL
    package let hostIdentifier: String

    package init(applicationSupportDirectory: URL, hostIdentifier: String) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.hostIdentifier = hostIdentifier
    }

    package static func live() throws -> Self {
        guard let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CodexKitManagedStorageError.applicationSupportDirectoryUnavailable
        }

        return Self(
            applicationSupportDirectory: applicationSupportDirectory,
            hostIdentifier: safeHostIdentifier(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                processName: ProcessInfo.processInfo.processName
            )
        )
    }

    package func fileURL(for kind: CodexKitManagedStoreKind) -> URL {
        applicationSupportDirectory
            .appendingPathComponent(hostIdentifier, isDirectory: true)
            .appendingPathComponent("CodexKit", isDirectory: true)
            .appendingPathComponent(kind.adapterDirectory, isDirectory: true)
            .appendingPathComponent(kind.filename, isDirectory: false)
    }

    /// A caller may choose a containing directory, but never the database filenames or schemas.
    package static func fileURL(in storageDirectory: URL, for kind: CodexKitManagedStoreKind) throws -> URL {
        guard storageDirectory.isFileURL else { throw CodexKitManagedStorageError.invalidStorageDirectory }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: storageDirectory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw CodexKitManagedStorageError.invalidStorageDirectory
        }
        return storageDirectory.standardizedFileURL
            .appendingPathComponent("CodexKit", isDirectory: true)
            .appendingPathComponent(kind.adapterDirectory, isDirectory: true)
            .appendingPathComponent(kind.filename, isDirectory: false)
    }

    private static func safeHostIdentifier(
        bundleIdentifier: String?,
        processName: String
    ) -> String {
        let candidate = bundleIdentifier ?? processName
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let scalars = candidate.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let component = String(scalars.prefix(128))
        guard !component.isEmpty, component != ".", component != ".." else {
            return "application"
        }
        return component
    }
}
