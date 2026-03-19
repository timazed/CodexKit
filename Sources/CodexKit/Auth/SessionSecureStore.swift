import Foundation

public protocol SessionSecureStoring: Sendable {
    func loadSession() throws -> ChatGPTSession?
    func saveSession(_ session: ChatGPTSession) throws
    func deleteSession() throws
}
