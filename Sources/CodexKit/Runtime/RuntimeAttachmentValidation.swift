import Foundation

package struct RuntimeAttachmentPromotionJournal: Codable {
    let storageKeys: [String]
}

package enum RuntimeAttachmentStoreError: Error, Equatable {
    case invalidStorageKey(String)
    case integrityCheckFailed(String)
    case missingPreparedAttachment(recordID: String, index: Int)
    case invalidAttachmentMetadata
    case tooManyAttachments(count: Int, limit: Int)
    case attachmentTooLarge(id: String, limit: Int)
    case attachmentBatchTooLarge(limit: Int)
}

extension RuntimeAttachmentStore {
    func validateAttachments(in messages: [AgentMessage]) throws {
        var attachmentCount = 0
        var totalByteCount = 0
        for message in messages {
            guard message.images.count <= AgentStoreLimits.maximumImageCountPerMessage else {
                throw RuntimeAttachmentStoreError.tooManyAttachments(
                    count: message.images.count,
                    limit: AgentStoreLimits.maximumImageCountPerMessage
                )
            }
            for attachment in message.images {
                try validate(attachment)
                let (nextCount, countOverflow) = attachmentCount.addingReportingOverflow(1)
                let (nextBytes, byteOverflow) = totalByteCount.addingReportingOverflow(
                    attachment.data.count
                )
                guard !countOverflow, !byteOverflow else {
                    throw RuntimeAttachmentStoreError.attachmentBatchTooLarge(
                        limit: AgentStoreLimits.maximumImageBytesPerWrite
                    )
                }
                attachmentCount = nextCount
                totalByteCount = nextBytes
            }
        }
        guard attachmentCount <= AgentStoreLimits.maximumImageCountPerWrite else {
            throw RuntimeAttachmentStoreError.tooManyAttachments(
                count: attachmentCount,
                limit: AgentStoreLimits.maximumImageCountPerWrite
            )
        }
        guard totalByteCount <= AgentStoreLimits.maximumImageBytesPerWrite else {
            throw RuntimeAttachmentStoreError.attachmentBatchTooLarge(
                limit: AgentStoreLimits.maximumImageBytesPerWrite
            )
        }
    }

    func validate(_ attachment: AgentImageAttachment) throws {
        guard !attachment.id.isEmpty,
              attachment.id.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount,
              !attachment.mimeType.isEmpty,
              attachment.mimeType.utf8.count <= AgentStoreLimits.maximumIdentifierByteCount else {
            throw RuntimeAttachmentStoreError.invalidAttachmentMetadata
        }
        guard attachment.data.count <= AgentStoreLimits.maximumImageByteCount else {
            throw RuntimeAttachmentStoreError.attachmentTooLarge(
                id: attachment.id,
                limit: AgentStoreLimits.maximumImageByteCount
            )
        }
    }
}
