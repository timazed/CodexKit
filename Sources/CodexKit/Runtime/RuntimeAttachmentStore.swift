import CryptoKit
import Foundation

package struct RuntimePreparedAttachments: Sendable {
    fileprivate let byWriteKey: [RuntimeAttachmentWriteKey: PersistedImageAttachment]

    package static let empty = RuntimePreparedAttachments(byWriteKey: [:])

    package func reference(
        for attachment: AgentImageAttachment,
        threadID: String,
        recordID: String,
        index: Int
    ) throws -> PersistedImageAttachment {
        let key = RuntimeAttachmentWriteKey(
            attachment: attachment,
            threadID: threadID,
            recordID: recordID,
            index: index
        )
        guard let reference = byWriteKey[key] else {
            throw RuntimeAttachmentStoreError.missingPreparedAttachment(recordID: recordID, index: index)
        }
        return reference
    }
}

package struct RuntimeAttachmentWriteBatch: Sendable {
    package let preparedAttachments: RuntimePreparedAttachments
    fileprivate let stagingRootURL: URL?
    fileprivate let stagedStorageKeys: Set<String>
    fileprivate let replacementStorageKeys: Set<String>
    fileprivate var promotionJournalURL: URL?
    package fileprivate(set) var newlyPromotedStorageKeys: Set<String> = []

    fileprivate init(
        preparedAttachments: RuntimePreparedAttachments,
        stagingRootURL: URL?,
        stagedStorageKeys: Set<String> = [],
        replacementStorageKeys: Set<String> = []
    ) {
        self.preparedAttachments = preparedAttachments
        self.stagingRootURL = stagingRootURL
        self.stagedStorageKeys = stagedStorageKeys
        self.replacementStorageKeys = replacementStorageKeys
        self.promotionJournalURL = nil
    }
}

fileprivate struct RuntimeAttachmentWriteKey: Hashable, Sendable {
    let threadID: String
    let recordID: String
    let index: Int
    let attachmentID: String
    let mimeType: AgentImageMIMEType
    let contentDigest: String
    let generationMetadata: AgentImageGenerationMetadata?
    let detail: AgentImageDetail?

    init(
        attachment: AgentImageAttachment,
        threadID: String,
        recordID: String,
        index: Int
    ) {
        self.threadID = threadID
        self.recordID = recordID
        self.index = index
        self.attachmentID = attachment.id
        self.mimeType = attachment.mimeType
        self.contentDigest = RuntimeAttachmentStore.digest(attachment.data)
        self.generationMetadata = attachment.generationMetadata
        self.detail = attachment.detail
    }
}

package struct RuntimeAttachmentStore: Sendable {
    package let rootURL: URL
    package let legacyReadRootURLs: [URL]

    private var stagingDirectoryURL: URL {
        rootURL.appendingPathComponent(".codexkit-staging", isDirectory: true)
    }

    package var promotionJournalDirectoryURL: URL {
        rootURL.appendingPathComponent(".codexkit-promotion-journal", isDirectory: true)
    }

    private var reconciliationMarkerURL: URL {
        rootURL.appendingPathComponent(".codexkit-reconciled-v1", isDirectory: false)
    }

    package init(
        rootURL: URL,
        legacyReadRootURLs: [URL] = []
    ) {
        self.rootURL = rootURL
        self.legacyReadRootURLs = legacyReadRootURLs.filter {
            $0.standardizedFileURL != rootURL.standardizedFileURL
        }
    }

    package static func sidecarDirectoryURL(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appendingPathComponent("\(storeURL.lastPathComponent).codexkit-state", isDirectory: true)
    }

    package static func legacySidecarDirectoryURL(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appendingPathComponent(
                "\(storeURL.deletingPathExtension().lastPathComponent).codexkit-state",
                isDirectory: true
            )
    }

    package static func safePathComponent(_ value: String) -> String {
        digest(Data(value.utf8))
    }

    package func prepare() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    package func removeAbandonedStagingFiles() throws {
        guard FileManager.default.fileExists(atPath: stagingDirectoryURL.path) else { return }
        try FileManager.default.removeItem(at: stagingDirectoryURL)
    }

    package func stageAttachments(
        in operations: [AgentStoreWriteOperation]
    ) throws -> RuntimeAttachmentWriteBatch {
        try stageAttachments(in: attachmentMessages(in: operations))
    }

    package func stageAttachments(
        in state: StoredRuntimeState
    ) throws -> RuntimeAttachmentWriteBatch {
        try stageAttachments(in: attachmentMessages(in: state))
    }

    package func promote(_ batch: inout RuntimeAttachmentWriteBatch) throws {
        guard let stagingRootURL = batch.stagingRootURL else { return }
        let fileManager = FileManager.default
        let journalURL = try writePromotionJournal(storageKeys: batch.stagedStorageKeys)
        batch.promotionJournalURL = journalURL
        do {
            for storageKey in batch.stagedStorageKeys.sorted() {
                let sourceURL = try validatedURL(for: storageKey, under: stagingRootURL)
                let destinationURL = try validatedURL(for: storageKey, under: rootURL)
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destinationURL.path) {
                    if batch.replacementStorageKeys.contains(storageKey) {
                        let replacementData = try readValidatedAttachmentData(at: sourceURL)
                        try replacementData.write(to: destinationURL, options: .atomic)
                        try? fileManager.removeItem(at: sourceURL)
                        batch.newlyPromotedStorageKeys.insert(storageKey)
                        continue
                    }
                    try? fileManager.removeItem(at: sourceURL)
                    continue
                }
                do {
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                    batch.newlyPromotedStorageKeys.insert(storageKey)
                } catch CocoaError.fileWriteFileExists {
                    try? fileManager.removeItem(at: sourceURL)
                }
            }
            try? fileManager.removeItem(at: stagingRootURL)
            removeStagingDirectoryIfEmpty()
        } catch {
            try? fileManager.removeItem(at: stagingRootURL)
            removeStagingDirectoryIfEmpty()
            throw error
        }
    }

    package func complete(_ batch: RuntimeAttachmentWriteBatch) throws {
        guard let journalURL = batch.promotionJournalURL else { return }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            try FileManager.default.removeItem(at: journalURL)
        }
        removePromotionJournalDirectoryIfEmpty()
    }

    package func completePendingPromotionRecovery() throws {
        guard FileManager.default.fileExists(atPath: promotionJournalDirectoryURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: promotionJournalDirectoryURL)
    }

    package var requiresFullReconciliation: Bool {
        !FileManager.default.fileExists(atPath: reconciliationMarkerURL.path)
    }

    package func markFullReconciliationComplete() throws {
        try prepare()
        try Data("1".utf8).write(to: reconciliationMarkerURL, options: .atomic)
    }

    package func markFullReconciliationRequired() throws {
        guard FileManager.default.fileExists(atPath: reconciliationMarkerURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: reconciliationMarkerURL)
    }

    package func discard(_ batch: RuntimeAttachmentWriteBatch) {
        guard let stagingRootURL = batch.stagingRootURL else { return }
        try? FileManager.default.removeItem(at: stagingRootURL)
        removeStagingDirectoryIfEmpty()
    }

    package func persist(
        _ attachment: AgentImageAttachment,
        threadID: String,
        recordID: String,
        index: Int
    ) throws -> PersistedImageAttachment {
        try validate(attachment)
        try prepare()
        let relativePath = storageKey(
            for: attachment,
            threadID: threadID,
            recordID: recordID,
            index: index
        )
        let fileURL = try validatedURL(for: relativePath, under: rootURL)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try attachment.data.write(to: fileURL, options: .atomic)
        } else if try !storedDataMatchesStorageKey(at: fileURL, storageKey: relativePath) {
            try attachment.data.write(to: fileURL, options: .atomic)
        }
        return reference(for: attachment, storageKey: relativePath)
    }

    package func load(_ attachment: PersistedImageAttachment) throws -> AgentImageAttachment {
        let primaryURL = try validatedURL(for: attachment.storageKey, under: rootURL)
        let data: Data
        if FileManager.default.fileExists(atPath: primaryURL.path) {
            data = try readValidatedAttachmentData(at: primaryURL)
        } else if let legacyURL = try legacyURL(for: attachment.storageKey) {
            data = try readValidatedAttachmentData(at: legacyURL)
            guard dataMatchesStorageKey(data, storageKey: attachment.storageKey) else {
                throw RuntimeAttachmentStoreError.integrityCheckFailed(attachment.storageKey)
            }
            try FileManager.default.createDirectory(
                at: primaryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: primaryURL.path) {
                try data.write(to: primaryURL, options: .atomic)
            }
        } else {
            data = try Data(contentsOf: primaryURL)
        }
        guard dataMatchesStorageKey(data, storageKey: attachment.storageKey) else {
            throw RuntimeAttachmentStoreError.integrityCheckFailed(attachment.storageKey)
        }
        return AgentImageAttachment(
            id: attachment.id,
            mimeType: attachment.mimeType,
            data: data,
            generationMetadata: attachment.generationMetadata,
            detail: attachment.detail
        )
    }

    package func migrate(_ storageKeys: some Sequence<String>) throws {
        try prepare()
        for storageKey in Set(storageKeys) {
            let destinationURL = try validatedURL(for: storageKey, under: rootURL)
            guard !FileManager.default.fileExists(atPath: destinationURL.path),
                  let sourceURL = try legacyURL(for: storageKey)
            else { continue }
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            } catch CocoaError.fileWriteFileExists {
                // Another store instance completed the same idempotent migration.
            }
        }
    }

    package func remove(storageKeys: some Sequence<String>) throws {
        for storageKey in Set(storageKeys) {
            let fileURL = try validatedURL(for: storageKey, under: rootURL)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            try FileManager.default.removeItem(at: fileURL)
            try removeEmptyParents(startingAt: fileURL.deletingLastPathComponent())
        }
    }

    private func stageAttachments(
        in messages: [AgentMessage]
    ) throws -> RuntimeAttachmentWriteBatch {
        try validateAttachments(in: messages)
        let attachments = messages.flatMap { message in
            message.images.enumerated().map { index, attachment in
                (message, index, attachment)
            }
        }
        guard !attachments.isEmpty else {
            return RuntimeAttachmentWriteBatch(
                preparedAttachments: .empty,
                stagingRootURL: nil
            )
        }

        try prepare()
        let stagingRootURL = stagingDirectoryURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagingStore = RuntimeAttachmentStore(rootURL: stagingRootURL)
        var references: [RuntimeAttachmentWriteKey: PersistedImageAttachment] = [:]
        var stagedStorageKeys = Set<String>()
        var replacementStorageKeys = Set<String>()
        do {
            for (message, index, attachment) in attachments {
                let key = RuntimeAttachmentWriteKey(
                    attachment: attachment,
                    threadID: message.threadID,
                    recordID: message.id,
                    index: index
                )
                if references[key] == nil {
                    let storageKey = storageKey(
                        for: attachment,
                        threadID: message.threadID,
                        recordID: message.id,
                        index: index
                    )
                    let reference = reference(for: attachment, storageKey: storageKey)
                    references[key] = reference
                    let destinationURL = try validatedURL(for: storageKey, under: rootURL)
                    let destinationExists = FileManager.default.fileExists(atPath: destinationURL.path)
                    let destinationMatches = try !destinationExists ||
                        storedDataMatchesStorageKey(at: destinationURL, storageKey: storageKey)
                    if !destinationMatches {
                        replacementStorageKeys.insert(storageKey)
                    }
                    if (!destinationExists || !destinationMatches),
                       stagedStorageKeys.insert(storageKey).inserted {
                        _ = try stagingStore.persist(
                            attachment,
                            threadID: message.threadID,
                            recordID: message.id,
                            index: index
                        )
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: stagingRootURL)
            removeStagingDirectoryIfEmpty()
            throw error
        }
        return RuntimeAttachmentWriteBatch(
            preparedAttachments: RuntimePreparedAttachments(byWriteKey: references),
            stagingRootURL: stagedStorageKeys.isEmpty ? nil : stagingRootURL,
            stagedStorageKeys: stagedStorageKeys,
            replacementStorageKeys: replacementStorageKeys
        )
    }

    private func reference(
        for attachment: AgentImageAttachment,
        storageKey: String
    ) -> PersistedImageAttachment {
        PersistedImageAttachment(
            id: attachment.id,
            mimeType: attachment.mimeType.rawValue,
            storageKey: storageKey,
            generationMetadata: attachment.generationMetadata,
            detail: attachment.detail
        )
    }

    private func storageKey(
        for attachment: AgentImageAttachment,
        threadID: String,
        recordID: String,
        index: Int
    ) -> String {
        let threadComponent = Self.safePathComponent(threadID)
        let recordComponent = Self.safePathComponent(recordID)
        let attachmentComponent = Self.safePathComponent(attachment.id)
        let contentComponent = Self.digest(attachment.data)
        let fileName = "\(index)-\(attachmentComponent)-\(contentComponent).\(fileExtension(for: attachment.mimeType))"
        return threadComponent + "/" + recordComponent + "/" + fileName
    }

    private func fileExtension(for mimeType: AgentImageMIMEType) -> String {
        let normalized = AgentImageMIMEType(rawValue: mimeType.rawValue.lowercased())
        return switch normalized {
        case .jpeg: "jpg"
        case .png: "png"
        case .gif: "gif"
        case .webp: "webp"
        case .heic: "heic"
        default: normalized.rawValue == "image/jpg" ? "jpg" : "bin"
        }
    }

    fileprivate static func digest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    private func storedDataMatchesStorageKey(
        at url: URL,
        storageKey: String
    ) throws -> Bool {
        dataMatchesStorageKey(
            try readValidatedAttachmentData(at: url),
            storageKey: storageKey
        )
    }

    private func readValidatedAttachmentData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              (values.fileSize ?? 0) <= AgentStoreLimits.maximumImageByteCount else {
            throw RuntimeAttachmentStoreError.attachmentTooLarge(
                id: url.lastPathComponent,
                limit: AgentStoreLimits.maximumImageByteCount
            )
        }
        return try Data(contentsOf: url)
    }

    private func dataMatchesStorageKey(_ data: Data, storageKey: String) -> Bool {
        guard let expectedDigest = contentDigest(from: storageKey) else {
            // Released legacy paths did not all carry a content digest.
            return true
        }
        return Self.digest(data) == expectedDigest
    }

    private func contentDigest(from storageKey: String) -> String? {
        let filename = (storageKey as NSString).lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        guard let digest = stem.split(separator: "-").last.map(String.init),
              digest.count == 64,
              digest.unicodeScalars.allSatisfy({
                  (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
              }) else {
            return nil
        }
        return digest
    }

    private func legacyURL(for storageKey: String) throws -> URL? {
        for legacyRootURL in legacyReadRootURLs {
            let candidate = try validatedURL(for: storageKey, under: legacyRootURL)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func validatedURL(for storageKey: String, under root: URL) throws -> URL {
        let components = storageKey.split(separator: "/", omittingEmptySubsequences: false)
        guard !storageKey.isEmpty,
              storageKey.utf8.count <= AgentStoreLimits.maximumAttachmentStorageKeyByteCount,
              !(storageKey as NSString).isAbsolutePath,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw RuntimeAttachmentStoreError.invalidStorageKey(storageKey)
        }

        let standardizedRoot = root.standardizedFileURL
        let candidate = standardizedRoot
            .appendingPathComponent(storageKey, isDirectory: false)
            .standardizedFileURL
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(standardizedRoot.path + "/"),
              resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/")
        else {
            throw RuntimeAttachmentStoreError.invalidStorageKey(storageKey)
        }
        return candidate
    }

    package func validateStorageKey(_ storageKey: String) throws {
        _ = try validatedURL(for: storageKey, under: rootURL)
    }

    private func removeEmptyParents(startingAt directoryURL: URL) throws {
        let standardizedRoot = rootURL.standardizedFileURL
        var current = directoryURL.standardizedFileURL
        while current != standardizedRoot,
              current.path.hasPrefix(standardizedRoot.path + "/") {
            let contents = try FileManager.default.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: nil
            )
            guard contents.isEmpty else { return }
            try FileManager.default.removeItem(at: current)
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }

    private func removeStagingDirectoryIfEmpty() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: stagingDirectoryURL,
            includingPropertiesForKeys: nil
        ), contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
    }

    private func writePromotionJournal(storageKeys: Set<String>) throws -> URL {
        try FileManager.default.createDirectory(
            at: promotionJournalDirectoryURL,
            withIntermediateDirectories: true
        )
        let journalURL = promotionJournalDirectoryURL
            .appendingPathComponent(UUID().uuidString.lowercased())
            .appendingPathExtension("json")
        let journal = RuntimeAttachmentPromotionJournal(storageKeys: storageKeys.sorted())
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        return journalURL
    }

    private func removePromotionJournalDirectoryIfEmpty() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: promotionJournalDirectoryURL,
            includingPropertiesForKeys: nil
        ), contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: promotionJournalDirectoryURL)
    }
}
