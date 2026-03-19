import CodexKit
import CodexKitUI
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AgentDemoViewModel: @unchecked Sendable {
    nonisolated private static let logger = Logger(
        subsystem: "ai.assistantruntime.demoapp",
        category: "DemoTool"
    )

    private(set) var session: ChatGPTSession?
    private(set) var threads: [AgentThread] = []
    private(set) var messages: [AgentMessage] = []
    private(set) var streamingText = ""
    private(set) var lastError: String?
    private(set) var isAuthenticating = false
    var composerText = ""

    let approvalInbox: ApprovalInbox
    let deviceCodePromptCoordinator: DeviceCodePromptCoordinator

    private let redirectURI: URL
    private let model: String
    private let enableWebSearch: Bool
    private let stateURL: URL?
    private let keychainAccount: String

    private var runtime: AgentRuntime
    private var activeThreadID: String?

    init(
        runtime: AgentRuntime,
        redirectURI: URL,
        model: String,
        enableWebSearch: Bool,
        stateURL: URL?,
        keychainAccount: String,
        approvalInbox: ApprovalInbox,
        deviceCodePromptCoordinator: DeviceCodePromptCoordinator = DeviceCodePromptCoordinator()
    ) {
        self.runtime = runtime
        self.redirectURI = redirectURI
        self.model = model
        self.enableWebSearch = enableWebSearch
        self.stateURL = stateURL
        self.keychainAccount = keychainAccount
        self.approvalInbox = approvalInbox
        self.deviceCodePromptCoordinator = deviceCodePromptCoordinator
    }

    var activeThread: AgentThread? {
        guard let activeThreadID else {
            return nil
        }
        return threads.first { $0.id == activeThreadID }
    }

    func restore() async {
        do {
            _ = try await runtime.restore()
            await registerDemoTool()
            await refreshSnapshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signIn(using authenticationMethod: DemoAuthenticationMethod) async {
        guard !isAuthenticating else {
            return
        }

        isAuthenticating = true
        lastError = nil
        runtime = AgentDemoRuntimeFactory.makeRuntime(
            authenticationMethod: authenticationMethod,
            redirectURI: redirectURI,
            model: model,
            enableWebSearch: enableWebSearch,
            stateURL: stateURL,
            keychainAccount: keychainAccount,
            approvalInbox: approvalInbox,
            deviceCodePromptCoordinator: deviceCodePromptCoordinator
        )

        defer {
            isAuthenticating = false
        }

        do {
            _ = try await runtime.restore()
            await registerDemoTool()
            session = try await runtime.signIn()
            await refreshSnapshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func registerDemoTool() async {
        let definition = ToolDefinition(
            name: "demo_calculate_shipping_quote",
            description: "Calculate a deterministic demo shipping quote, including price and estimated delivery days.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "destination_zone": .object([
                        "type": .string("string"),
                        "description": .string("Destination zone: A, B, C, or D."),
                    ]),
                    "weight_kg": .object([
                        "type": .string("number"),
                        "description": .string("Package weight in kilograms."),
                    ]),
                    "speed": .object([
                        "type": .string("string"),
                        "description": .string("Shipping speed: standard, express, or priority."),
                    ]),
                    "signature_required": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether signature on delivery is required."),
                    ]),
                ]),
            ]),
            approvalPolicy: .requiresApproval,
            approvalMessage: "Allow the demo app to calculate a shipping quote?"
        )

        do {
            try await runtime.replaceTool(definition, executor: AnyToolExecutor { invocation, _ in
                Self.logger.info(
                    "Executing tool \(invocation.toolName, privacy: .public) with arguments: \(String(describing: invocation.arguments), privacy: .public)"
                )
                let result = Self.makeShippingQuote(invocation: invocation)
                Self.logger.info(
                    "Tool \(invocation.toolName, privacy: .public) returned: \(result.primaryText ?? "<no text result>", privacy: .public)"
                )
                return result
            })
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createThread() async {
        do {
            let thread = try await runtime.createThread()
            threads = await runtime.threads()
            activeThreadID = thread.id
            messages = await runtime.messages(for: thread.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func activateThread(id: String) async {
        activeThreadID = id
        messages = await runtime.messages(for: id)
        streamingText = ""
    }

    func sendComposerText() async {
        guard !composerText.isEmpty else {
            return
        }

        if activeThreadID == nil {
            await createThread()
        }

        guard let activeThreadID else {
            lastError = "No active thread is available."
            return
        }

        let outgoingText = composerText
        composerText = ""
        streamingText = ""

        do {
            let stream = try await runtime.sendMessage(
                UserMessageRequest(text: outgoingText),
                in: activeThreadID
            )
            messages = await runtime.messages(for: activeThreadID)

            for try await event in stream {
                switch event {
                case let .threadStarted(thread):
                    threads = [thread] + threads.filter { $0.id != thread.id }

                case let .threadStatusChanged(threadID, status):
                    threads = threads.map { thread in
                        guard thread.id == threadID else {
                            return thread
                        }
                        var updated = thread
                        updated.status = status
                        updated.updatedAt = Date()
                        return updated
                    }

                case .turnStarted:
                    break

                case let .assistantMessageDelta(_, _, delta):
                    streamingText.append(delta)

                case let .messageCommitted(message):
                    messages.append(message)
                    if message.role == .assistant {
                        streamingText = ""
                    }

                case .approvalRequested:
                    break

                case .approvalResolved:
                    break

                case let .toolCallStarted(invocation):
                    Self.logger.info(
                        "Tool call requested: \(invocation.toolName, privacy: .public) with arguments: \(String(describing: invocation.arguments), privacy: .public)"
                    )

                case let .toolCallFinished(result):
                    Self.logger.info(
                        "Tool call finished: \(result.toolName, privacy: .public) success=\(result.success, privacy: .public) output=\(result.primaryText ?? "<no text result>", privacy: .public)"
                    )

                case .turnCompleted:
                    messages = await runtime.messages(for: activeThreadID)
                    threads = await runtime.threads()

                case let .turnFailed(error):
                    lastError = error.message
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func approvePendingRequest() {
        approvalInbox.approveCurrent()
    }

    func denyPendingRequest() {
        approvalInbox.denyCurrent()
    }

    func dismissError() {
        lastError = nil
    }

    func signOut() async {
        do {
            try await runtime.signOut()
            await deviceCodePromptCoordinator.clear()
            session = nil
            threads = []
            messages = []
            streamingText = ""
            composerText = ""
            activeThreadID = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshSnapshot() async {
        session = await runtime.currentSession()
        threads = await runtime.threads()

        let selectedThreadID = activeThreadID
        if let selectedThreadID,
           threads.contains(where: { $0.id == selectedThreadID }) {
            messages = await runtime.messages(for: selectedThreadID)
            return
        }

        if let firstThread = threads.first {
            activeThreadID = firstThread.id
            messages = await runtime.messages(for: firstThread.id)
        } else {
            activeThreadID = nil
            messages = []
        }
    }

    nonisolated private static func makeShippingQuote(invocation: ToolInvocation) -> ToolResultEnvelope {
        guard case let .object(arguments) = invocation.arguments else {
            return .failure(
                invocation: invocation,
                message: "The shipping quote tool expected object arguments."
            )
        }

        let destinationZone = arguments["destination_zone"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        let speed = arguments["speed"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "standard"
        let weightKilograms = arguments["weight_kg"]?.numberValue ?? 0
        let signatureRequired = arguments["signature_required"]?.boolValue ?? false

        let basePriceByZone: [String: Double] = [
            "A": 4.0,
            "B": 6.5,
            "C": 9.0,
            "D": 12.5,
        ]
        let speedMultipliers: [String: Double] = [
            "standard": 1.0,
            "express": 1.6,
            "priority": 2.1,
        ]
        let deliveryDaysBySpeedAndZone: [String: [String: Int]] = [
            "standard": ["A": 2, "B": 4, "C": 6, "D": 8],
            "express": ["A": 1, "B": 2, "C": 3, "D": 4],
            "priority": ["A": 1, "B": 1, "C": 2, "D": 3],
        ]

        guard let zoneBasePrice = basePriceByZone[destinationZone] else {
            return .failure(
                invocation: invocation,
                message: "Unknown destination zone. Use A, B, C, or D."
            )
        }

        guard let speedMultiplier = speedMultipliers[speed] else {
            return .failure(
                invocation: invocation,
                message: "Unknown shipping speed. Use standard, express, or priority."
            )
        }

        guard weightKilograms > 0 else {
            return .failure(
                invocation: invocation,
                message: "Weight must be greater than zero kilograms."
            )
        }

        let signatureSurcharge = signatureRequired ? 2.5 : 0
        let subtotal = (zoneBasePrice + (weightKilograms * 1.75)) * speedMultiplier
        let total = round((subtotal + signatureSurcharge) * 100) / 100
        let deliveryDays = deliveryDaysBySpeedAndZone[speed]?[destinationZone] ?? 0

        return .success(
            invocation: invocation,
            text: """
            quote[zone=\(destinationZone), weightKg=\(Self.formattedDecimal(weightKilograms)), speed=\(speed), signatureRequired=\(signatureRequired ? "yes" : "no"), totalUSD=\(Self.formattedDecimal(total)), estimatedDeliveryDays=\(deliveryDays), reference=DEMO-\(destinationZone)-\(speed.uppercased())]
            """
        )
    }

    nonisolated private static func formattedDecimal(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private extension JSONValue {
    var numberValue: Double? {
        guard case let .number(value) = self else {
            return nil
        }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else {
            return nil
        }
        return value
    }
}
