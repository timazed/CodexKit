import Foundation

package final class RuntimeAttachmentStorageKeyIterator: @unchecked Sendable {
    private let rootPath: String
    private let enumerator: FileManager.DirectoryEnumerator?

    init(rootURL: URL) {
        rootPath = rootURL.standardizedFileURL.path
        enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    }

    package func nextBatch(limit: Int = 256) throws -> [String] {
        guard limit > 0, let enumerator else { return [] }
        var result: [String] = []
        result.reserveCapacity(limit)
        while result.count < limit,
              let fileURL = enumerator.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = fileURL.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            result.append(String(path.dropFirst(rootPath.count + 1)))
        }
        return result
    }
}

package final class RuntimeAttachmentPromotionKeyIterator: @unchecked Sendable {
    private let store: RuntimeAttachmentStore
    private let enumerator: FileManager.DirectoryEnumerator?
    private var pendingKeys: ArraySlice<String> = []

    init(store: RuntimeAttachmentStore) {
        self.store = store
        enumerator = FileManager.default.enumerator(
            at: store.promotionJournalDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
    }

    package func nextBatch(limit: Int = 256) throws -> [String] {
        guard limit > 0 else { return [] }
        var result: [String] = []
        result.reserveCapacity(limit)
        while result.count < limit {
            if let key = pendingKeys.popFirst() {
                try store.validateStorageKey(key)
                result.append(key)
                continue
            }
            guard let journalURL = enumerator?.nextObject() as? URL else { break }
            let values = try journalURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard values.isRegularFile == true, journalURL.pathExtension == "json" else {
                continue
            }
            guard (values.fileSize ?? 0) <= AgentStoreLimits.maximumPromotionJournalByteCount else {
                throw RuntimeAttachmentStoreError.attachmentBatchTooLarge(
                    limit: AgentStoreLimits.maximumPromotionJournalByteCount
                )
            }
            let journal = try JSONDecoder().decode(
                RuntimeAttachmentPromotionJournal.self,
                from: Data(contentsOf: journalURL)
            )
            guard journal.storageKeys.count <= AgentStoreLimits.maximumImageCountPerWrite else {
                throw RuntimeAttachmentStoreError.tooManyAttachments(
                    count: journal.storageKeys.count,
                    limit: AgentStoreLimits.maximumImageCountPerWrite
                )
            }
            pendingKeys = journal.storageKeys[...]
        }
        return result
    }
}

extension RuntimeAttachmentStore {
    package func makeStorageKeyIterator() -> RuntimeAttachmentStorageKeyIterator {
        RuntimeAttachmentStorageKeyIterator(rootURL: rootURL)
    }

    package func makePendingPromotionStorageKeyIterator()
        -> RuntimeAttachmentPromotionKeyIterator {
        RuntimeAttachmentPromotionKeyIterator(store: self)
    }
}
