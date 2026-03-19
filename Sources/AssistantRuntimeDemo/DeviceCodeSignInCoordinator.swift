import AssistantRuntimeKit
import Foundation
import Observation

@MainActor
@Observable
public final class DeviceCodeSignInCoordinator: ChatGPTDeviceCodePresenting, @unchecked Sendable {
    public private(set) var currentPrompt: ChatGPTDeviceCodePrompt?

    public init() {}

    public func present(prompt: ChatGPTDeviceCodePrompt) async {
        currentPrompt = prompt
    }

    public func clear() async {
        currentPrompt = nil
    }
}
