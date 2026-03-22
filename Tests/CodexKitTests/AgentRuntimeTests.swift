import CodexKit
import XCTest

private struct AutoApprovalPresenter: ApprovalPresenting {
    func requestApproval(_ request: ApprovalRequest) async throws -> ApprovalDecision {
        XCTAssertEqual(request.toolInvocation.toolName, "demo_lookup_profile")
        return .approved
    }
}

private struct ShippingReplyDraft: AgentStructuredOutput, Equatable {
    let reply: String
    let priority: String

    static let responseFormat = AgentStructuredOutputFormat(
        name: "shipping_reply_draft",
        description: "A concise shipping support reply draft.",
        schema: .object(
            properties: [
                "reply": .string(),
                "priority": .string(),
            ],
            required: ["reply", "priority"],
            additionalProperties: false
        )
    )
}

final class AgentRuntimeTests: XCTestCase {
    func testSendMessageReturnsFinalAssistantMessageText() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Complete")
        let reply = try await runtime.sendMessage(
            UserMessageRequest(text: "Hello there"),
            in: thread.id
        )

        XCTAssertEqual(reply, "Echo: Hello there")
    }

    func testSendMessageExpectingStructuredTypeDecodesTypedResponse() async throws {
        let backend = InMemoryAgentBackend(
            structuredResponseText: #"{"reply":"Your order is already in transit.","priority":"high"}"#
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Structured")
        let reply = try await runtime.sendMessage(
            UserMessageRequest(text: "Draft a shipping reply."),
            in: thread.id,
            expecting: ShippingReplyDraft.self
        )

        XCTAssertEqual(
            reply,
            ShippingReplyDraft(
                reply: "Your order is already in transit.",
                priority: "high"
            )
        )

        let formats = await backend.receivedResponseFormats()
        XCTAssertEqual(formats.last??.name, "shipping_reply_draft")
    }

    func testStructuredDecodeFailureThrowsRuntimeError() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(
                structuredResponseText: #"{"unexpected":"value"}"#
            ),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Structured Failure")

        await XCTAssertThrowsErrorAsync(
            try await runtime.sendMessage(
                UserMessageRequest(text: "Draft a shipping reply."),
                in: thread.id,
                expecting: ShippingReplyDraft.self
            )
        ) { error in
            let runtimeError = error as? AgentRuntimeError
            XCTAssertEqual(runtimeError?.code, "structured_output_decoding_failed")
            XCTAssertTrue(runtimeError?.message.contains("ShippingReplyDraft") == true)
        }
    }

    func testImportedContentInitializerBuildsMessageWithSharedURLs() async throws {
        let content = AgentImportedContent(
            textSnippets: ["Summarize this article."],
            urls: [try XCTUnwrap(URL(string: "https://example.com/story"))],
            images: [.png(Data([0x89, 0x50, 0x4E, 0x47]))]
        )

        let request = UserMessageRequest(
            prompt: "Give me a concise summary.",
            importedContent: content
        )

        XCTAssertTrue(request.hasContent)
        XCTAssertEqual(request.images.count, 1)
        XCTAssertTrue(request.text.contains("Give me a concise summary."))
        XCTAssertTrue(request.text.contains("Summarize this article."))
        XCTAssertTrue(request.text.contains("Shared URLs:"))
        XCTAssertTrue(request.text.contains("https://example.com/story"))
    }

    func testThreadSkillsAreResolvedIntoInstructions() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            skills: [
                .init(
                    id: "health_coach",
                    name: "Health Coach",
                    instructions: "Coach users toward their daily step goals."
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(
            title: "Health",
            skillIDs: ["health_coach"]
        )
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "Give me my plan."),
            in: thread.id
        )
        for try await _ in stream {}

        let instructions = await backend.receivedInstructions()
        let resolvedInstructions = try XCTUnwrap(instructions.last)
        XCTAssertTrue(resolvedInstructions.contains("Thread Skills:"))
        XCTAssertTrue(resolvedInstructions.contains("[health_coach: Health Coach]"))
    }

    func testTurnSkillOverrideAppliesOnlyToCurrentTurn() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            skills: [
                .init(
                    id: "travel_planner",
                    name: "Travel Planner",
                    instructions: "Plan practical itineraries."
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread()

        let firstStream = try await runtime.streamMessage(
            UserMessageRequest(
                text: "Plan my trip.",
                skillOverrideIDs: ["travel_planner"]
            ),
            in: thread.id
        )
        for try await _ in firstStream {}

        let secondStream = try await runtime.streamMessage(
            UserMessageRequest(text: "Now answer normally."),
            in: thread.id
        )
        for try await _ in secondStream {}

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertTrue(instructions[0].contains("Turn Skill Override:"))
        XCTAssertTrue(instructions[0].contains("[travel_planner: Travel Planner]"))
        XCTAssertFalse(instructions[1].contains("Turn Skill Override:"))
        XCTAssertFalse(instructions[1].contains("[travel_planner: Travel Planner]"))
    }

    func testSetSkillIDsAffectsFutureTurnsOnly() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            skills: [
                .init(
                    id: "health_coach",
                    name: "Health Coach",
                    instructions: "Coach users toward step goals."
                ),
                .init(
                    id: "travel_planner",
                    name: "Travel Planner",
                    instructions: "Plan practical itineraries."
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(
            title: "Skills",
            skillIDs: ["health_coach"]
        )

        let firstStream = try await runtime.streamMessage(
            UserMessageRequest(text: "What should I walk today?"),
            in: thread.id
        )
        for try await _ in firstStream {}

        try await runtime.setSkillIDs(["travel_planner"], for: thread.id)

        let secondStream = try await runtime.streamMessage(
            UserMessageRequest(text: "Plan a weekend trip."),
            in: thread.id
        )
        for try await _ in secondStream {}

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertTrue(instructions[0].contains("[health_coach: Health Coach]"))
        XCTAssertFalse(instructions[0].contains("[travel_planner: Travel Planner]"))
        XCTAssertTrue(instructions[1].contains("[travel_planner: Travel Planner]"))
        XCTAssertFalse(instructions[1].contains("[health_coach: Health Coach]"))
    }

    func testThreadPersonaUsesBackendBaseInstructionsWhenRuntimeBaseIsUnset() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let supportPersona = AgentPersonaStack(layers: [
            .init(
                name: "domain",
                instructions: "You are an expert customer support agent for a shipping app."
            ),
            .init(
                name: "style",
                instructions: "Be concise, calm, and action-oriented."
            ),
        ])

        let thread = try await runtime.createThread(
            title: "Support Chat",
            personaStack: supportPersona
        )
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "How do I track my order?"),
            in: thread.id
        )

        for try await _ in stream {}

        let receivedInstructions = await backend.receivedInstructions()
        let resolvedInstructions = try XCTUnwrap(receivedInstructions.last)
        XCTAssertTrue(resolvedInstructions.contains("Base host instructions."))
        XCTAssertTrue(resolvedInstructions.contains("Thread Persona Layers:"))
        XCTAssertTrue(resolvedInstructions.contains("[domain]"))
        XCTAssertTrue(resolvedInstructions.contains("[style]"))
        XCTAssertLessThan(
            try XCTUnwrap(resolvedInstructions.range(of: "Base host instructions.")?.lowerBound),
            try XCTUnwrap(resolvedInstructions.range(of: "Thread Persona Layers:")?.lowerBound)
        )
    }

    func testTurnPersonaOverrideAppliesOnlyToCurrentTurn() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let supportPersona = AgentPersonaStack(layers: [
            .init(
                name: "support",
                instructions: "Act as a calm support specialist."
            ),
        ])
        let reviewerOverride = AgentPersonaStack(layers: [
            .init(
                name: "reviewer",
                instructions: "For this reply only, act as a strict reviewer and call out risks first."
            ),
        ])

        let thread = try await runtime.createThread(personaStack: supportPersona)

        let firstStream = try await runtime.streamMessage(
            UserMessageRequest(
                text: "Review this architecture.",
                personaOverride: reviewerOverride
            ),
            in: thread.id
        )
        for try await _ in firstStream {}

        let secondStream = try await runtime.streamMessage(
            UserMessageRequest(text: "Now just answer normally."),
            in: thread.id
        )
        for try await _ in secondStream {}

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertTrue(instructions[0].contains("Turn Persona Override:"))
        XCTAssertTrue(instructions[0].contains("[reviewer]"))
        XCTAssertFalse(instructions[1].contains("Turn Persona Override:"))
        XCTAssertFalse(instructions[1].contains("[reviewer]"))
        XCTAssertTrue(instructions[1].contains("[support]"))
    }

    func testSetPersonaStackAffectsFutureTurnsOnly() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let supportPersona = AgentPersonaStack(layers: [
            .init(name: "support", instructions: "Act as a support agent.")
        ])
        let plannerPersona = AgentPersonaStack(layers: [
            .init(name: "planner", instructions: "Act as a careful technical planner.")
        ])

        let thread = try await runtime.createThread(personaStack: supportPersona)

        let firstStream = try await runtime.streamMessage(
            UserMessageRequest(text: "Help me with support."),
            in: thread.id
        )
        for try await _ in firstStream {}

        try await runtime.setPersonaStack(plannerPersona, for: thread.id)

        let secondStream = try await runtime.streamMessage(
            UserMessageRequest(text: "Plan the migration."),
            in: thread.id
        )
        for try await _ in secondStream {}

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertTrue(instructions[0].contains("[support]"))
        XCTAssertFalse(instructions[0].contains("[planner]"))
        XCTAssertTrue(instructions[1].contains("[planner]"))
        XCTAssertFalse(instructions[1].contains("[support]"))
    }

    func testThreadPersonaStackPersistsAcrossRestore() async throws {
        let stateStore = InMemoryRuntimeStateStore()
        let secureStore = KeychainSessionSecureStore(
            service: "CodexKitTests.ChatGPTSession",
            account: UUID().uuidString
        )
        let personaStack = AgentPersonaStack(layers: [
            .init(name: "planner", instructions: "Act as a careful technical planner.")
        ])

        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: secureStore,
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()
        let thread = try await runtime.createThread(
            title: "Planning",
            personaStack: personaStack
        )

        let restoredRuntime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: secureStore,
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore
        ))

        _ = try await restoredRuntime.restore()

        let restoredStack = try await restoredRuntime.personaStack(for: thread.id)
        let restoredThreads = await restoredRuntime.threads()
        XCTAssertEqual(restoredStack, personaStack)
        XCTAssertEqual(restoredThreads.first?.personaStack, personaStack)
    }

    func testSetPersonaStackThrowsForMissingThread() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()

        await XCTAssertThrowsErrorAsync(
            try await runtime.setPersonaStack(
                AgentPersonaStack(layers: [
                    .init(name: "planner", instructions: "Act as a planner.")
                ]),
                for: "missing-thread"
            )
        ) { error in
            XCTAssertEqual(error as? AgentRuntimeError, .threadNotFound("missing-thread"))
        }
    }

    func testSetSkillIDsThrowsWhenSkillIsNotRegistered() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()
        let thread = try await runtime.createThread()

        await XCTAssertThrowsErrorAsync(
            try await runtime.setSkillIDs(["travel_planner"], for: thread.id)
        ) { error in
            XCTAssertEqual(
                error as? AgentRuntimeError,
                .skillsNotFound(["travel_planner"])
            )
        }
    }

    func testSkillPolicyBlocksDisallowedToolCalls() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            skills: [
                .init(
                    id: "strict_support",
                    name: "Strict Support",
                    instructions: "Answer directly.",
                    executionPolicy: .init(
                        allowedToolNames: ["allowed_tool"]
                    )
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        try await runtime.registerTool(
            ToolDefinition(
                name: "demo_lookup_profile",
                description: "Lookup profile",
                inputSchema: .object([:]),
                approvalPolicy: .automatic
            ),
            executor: AnyToolExecutor { invocation, _ in
                .success(invocation: invocation, text: "profile-ok")
            }
        )

        let thread = try await runtime.createThread(
            title: "Strict Tool Policy",
            skillIDs: ["strict_support"]
        )

        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "please use the tool"),
            in: thread.id
        )
        for try await _ in stream {}

        let messages = await runtime.messages(for: thread.id)
        let assistantText = messages
            .filter { $0.role == .assistant }
            .map(\.text)
            .joined(separator: "\n")
        XCTAssertTrue(assistantText.contains("not allowed by the active skill policy"))
    }

    func testSkillPolicyFailsTurnWhenRequiredToolIsMissing() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            skills: [
                .init(
                    id: "requires_tool",
                    name: "Requires Tool",
                    instructions: "Use the required tool.",
                    executionPolicy: .init(
                        requiredToolNames: ["demo_lookup_profile"]
                    )
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(
            title: "Required Tool",
            skillIDs: ["requires_tool"]
        )

        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "hello without tool"),
            in: thread.id
        )

        var sawTurnFailed = false
        var failureError: AgentRuntimeError?

        do {
            for try await event in stream {
                if case let .turnFailed(error) = event {
                    sawTurnFailed = true
                    failureError = error
                }
            }
            XCTFail("Expected turn stream to throw when required tools are missing.")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "skill_required_tools_missing")
        }

        XCTAssertTrue(sawTurnFailed)
        XCTAssertEqual(failureError?.code, "skill_required_tools_missing")
    }

    func testRuntimeRejectsSkillWithInvalidPolicyToolName() async throws {
        XCTAssertThrowsError(
            try AgentRuntime(configuration: .init(
                authProvider: DemoChatGPTAuthProvider(),
                secureStore: KeychainSessionSecureStore(
                    service: "CodexKitTests.ChatGPTSession",
                    account: UUID().uuidString
                ),
                backend: InMemoryAgentBackend(),
                approvalPresenter: AutoApprovalPresenter(),
                stateStore: InMemoryRuntimeStateStore(),
                skills: [
                    .init(
                        id: "invalid_policy",
                        name: "Invalid Policy",
                        instructions: "Invalid tool name policy.",
                        executionPolicy: .init(
                            requiredToolNames: ["bad tool name"]
                        )
                    ),
                ]
            ))
        ) { error in
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "invalid_skill_tool_name")
        }
    }

    func testResolvedInstructionsPreviewIncludesThreadPersonaAndSkills() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(baseInstructions: "Base host instructions."),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            skills: [
                .init(
                    id: "health_coach",
                    name: "Health Coach",
                    instructions: "Coach users toward their daily step goals."
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(
            title: "Preview",
            personaStack: AgentPersonaStack(layers: [
                .init(name: "planner", instructions: "Act as a planning specialist.")
            ]),
            skillIDs: ["health_coach"]
        )

        let preview = try await runtime.resolvedInstructionsPreview(
            for: thread.id,
            request: UserMessageRequest(text: "Give me a plan.")
        )

        XCTAssertTrue(preview.contains("Base host instructions."))
        XCTAssertTrue(preview.contains("Thread Persona Layers:"))
        XCTAssertTrue(preview.contains("[planner]"))
        XCTAssertTrue(preview.contains("Thread Skills:"))
        XCTAssertTrue(preview.contains("[health_coach: Health Coach]"))
    }

    func testResolvedInstructionsPreviewThrowsForMissingThread() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()

        await XCTAssertThrowsErrorAsync(
            try await runtime.resolvedInstructionsPreview(
                for: "missing-thread",
                request: UserMessageRequest(text: "hello")
            )
        ) { error in
            XCTAssertEqual(error as? AgentRuntimeError, .threadNotFound("missing-thread"))
        }
    }

    func testCreateThreadLoadsPersonaFromFileSource() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let personaText = "Act as a migration planning assistant focused on sequencing."
        let personaFile = try temporaryFile(
            with: personaText,
            pathExtension: "txt"
        )

        let thread = try await runtime.createThread(
            title: "Dynamic Persona",
            personaSource: .file(personaFile)
        )

        let personaStack = try XCTUnwrap(thread.personaStack)
        XCTAssertEqual(personaStack.layers.count, 1)
        XCTAssertEqual(personaStack.layers[0].instructions, personaText)

        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "Plan this migration."),
            in: thread.id
        )
        for try await _ in stream {}

        let instructions = await backend.receivedInstructions()
        let resolved = try XCTUnwrap(instructions.last)
        XCTAssertTrue(resolved.contains("Thread Persona Layers:"))
        XCTAssertTrue(resolved.contains(personaText))
    }

    func testRegisterSkillFromFileSourceCanBeUsedInThread() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let skillJSON = """
        {
          "id": "hydration_coach",
          "name": "Hydration Coach",
          "instructions": "Drive hydration execution with concrete water targets."
        }
        """
        let skillFile = try temporaryFile(
            with: skillJSON,
            pathExtension: "json"
        )

        _ = try await runtime.registerSkill(from: .file(skillFile))
        let registeredSkill = await runtime.skill(for: "hydration_coach")
        XCTAssertNotNil(registeredSkill)

        let thread = try await runtime.createThread(
            title: "Hydration",
            skillIDs: ["hydration_coach"]
        )

        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "Give me today's hydration plan."),
            in: thread.id
        )
        for try await _ in stream {}

        let instructions = await backend.receivedInstructions()
        let resolved = try XCTUnwrap(instructions.last)
        XCTAssertTrue(resolved.contains("Thread Skills:"))
        XCTAssertTrue(resolved.contains("[hydration_coach: Hydration Coach]"))
    }

    func testImageOnlyMessageIsAcceptedAndPersisted() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread()
        let image = AgentImageAttachment.png(Data([0x89, 0x50, 0x4E, 0x47]))

        let stream = try await runtime.streamMessage(
            UserMessageRequest(
                text: "",
                images: [image]
            ),
            in: thread.id
        )
        for try await _ in stream {}

        let messages = await runtime.messages(for: thread.id)
        let userMessage = try XCTUnwrap(messages.first(where: { $0.role == .user }))
        XCTAssertEqual(userMessage.images, [image])
        XCTAssertEqual(userMessage.text, "")
        XCTAssertEqual(userMessage.displayText, "Attached 1 image")

        let threads = await runtime.threads()
        let updatedThread = try XCTUnwrap(threads.first(where: { $0.id == thread.id }))
        XCTAssertEqual(updatedThread.title, "Image message")
    }

    func testAssistantImagesAreCommittedToThreadHistory() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: ImageReplyAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread()
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "Generate an image"),
            in: thread.id
        )
        for try await _ in stream {}

        let messages = await runtime.messages(for: thread.id)
        let assistantMessage = try XCTUnwrap(messages.first(where: { $0.role == .assistant }))
        XCTAssertEqual(assistantMessage.images.count, 1)
        XCTAssertEqual(assistantMessage.images.first?.mimeType, "image/png")
    }

    func testRestoreDecodesLegacyStateWithoutPersonaOrImages() async throws {
        let legacyStateJSON = """
        {
          "threads": [
            {
              "id": "thread-1",
              "title": "Legacy Thread",
              "createdAt": "2026-03-20T00:00:00Z",
              "updatedAt": "2026-03-20T00:00:00Z",
              "status": "idle"
            }
          ],
          "messagesByThread": {
            "thread-1": [
              {
                "id": "message-1",
                "threadID": "thread-1",
                "role": "assistant",
                "text": "Hello from legacy state",
                "createdAt": "2026-03-20T00:00:00Z"
              }
            ]
          }
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(StoredRuntimeState.self, from: Data(legacyStateJSON.utf8))

        XCTAssertEqual(state.threads.count, 1)
        XCTAssertEqual(state.threads.first?.personaStack, nil)
        XCTAssertEqual(state.messagesByThread["thread-1"]?.first?.images, [])
        XCTAssertEqual(state.messagesByThread["thread-1"]?.first?.text, "Hello from legacy state")
    }

    func testRuntimeStreamsToolApprovalAndCompletion() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))
        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        try await runtime.replaceTool(
            ToolDefinition(
                name: "demo_lookup_profile",
                description: "Lookup profile",
                inputSchema: .object([:]),
                approvalPolicy: .requiresApproval
            ),
            executor: AnyToolExecutor { invocation, _ in
                .success(invocation: invocation, text: "demo-result")
            }
        )

        let thread = try await runtime.createThread()
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "please use the tool"),
            in: thread.id
        )

        var sawApproval = false
        var sawToolResult = false
        var sawTurnCompleted = false

        for try await event in stream {
            switch event {
            case .approvalRequested:
                sawApproval = true
            case let .toolCallFinished(result):
                sawToolResult = true
                XCTAssertEqual(result.primaryText, "demo-result")
            case .turnCompleted:
                sawTurnCompleted = true
            default:
                break
            }
        }

        XCTAssertTrue(sawApproval)
        XCTAssertTrue(sawToolResult)
        XCTAssertTrue(sawTurnCompleted)

        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(messages.filter { $0.role == .assistant }.count, 1)
    }

    func testSendMessageRetriesUnauthorizedByRefreshingSession() async throws {
        let authProvider = RotatingDemoAuthProvider()
        let backend = UnauthorizedThenSuccessBackend()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: authProvider,
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()
        let thread = try await runtime.createThread()

        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "Hello"),
            in: thread.id
        )
        for try await _ in stream {}

        let refreshCount = await authProvider.refreshCount()
        XCTAssertEqual(refreshCount, 1)

        let attemptedTokens = await backend.attemptedAccessTokens()
        XCTAssertEqual(attemptedTokens.count, 2)
        XCTAssertEqual(attemptedTokens[0], "demo-access-token-initial")
        XCTAssertEqual(attemptedTokens[1], "demo-access-token-refreshed-1")

        let messages = await runtime.messages(for: thread.id)
        XCTAssertEqual(messages.filter { $0.role == .assistant }.count, 1)
    }

    func testCreateThreadRetriesUnauthorizedByRefreshingSession() async throws {
        let authProvider = RotatingDemoAuthProvider()
        let backend = UnauthorizedOnCreateThenSuccessBackend()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: authProvider,
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Recovered Thread")
        XCTAssertEqual(thread.title, "Recovered Thread")

        let refreshCount = await authProvider.refreshCount()
        XCTAssertEqual(refreshCount, 1)

        let attemptedTokens = await backend.attemptedAccessTokens()
        XCTAssertEqual(attemptedTokens.count, 2)
        XCTAssertEqual(attemptedTokens[0], "demo-access-token-initial")
        XCTAssertEqual(attemptedTokens[1], "demo-access-token-refreshed-1")
    }

    func testConfigurationRegistersInitialTools() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            tools: [
                .init(
                    definition: ToolDefinition(
                        name: "demo_lookup_profile",
                        description: "Lookup profile",
                        inputSchema: .object([:]),
                        approvalPolicy: .requiresApproval
                    ),
                    executor: AnyToolExecutor { invocation, _ in
                        .success(invocation: invocation, text: "demo-result")
                    }
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread()
        let stream = try await runtime.streamMessage(
            UserMessageRequest(text: "please use the tool"),
            in: thread.id
        )

        var sawToolResult = false

        for try await event in stream {
            if case let .toolCallFinished(result) = event {
                sawToolResult = true
                XCTAssertEqual(result.primaryText, "demo-result")
            }
        }

        XCTAssertTrue(sawToolResult)
    }

    private func temporaryFile(
        with content: String,
        pathExtension: String
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try Data(content.utf8).write(to: url, options: .atomic)
        return url
    }
}

private actor RotatingDemoAuthProvider: ChatGPTAuthProviding {
    private var refreshInvocationCount = 0

    func signInInteractively() async throws -> ChatGPTSession {
        ChatGPTSession(
            accessToken: "demo-access-token-initial",
            refreshToken: "demo-refresh-token",
            account: ChatGPTAccount(
                id: "demo-account",
                email: "demo@example.com",
                plan: .plus
            ),
            acquiredAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            isExternallyManaged: true
        )
    }

    func refresh(
        session: ChatGPTSession,
        reason _: ChatGPTAuthRefreshReason
    ) async throws -> ChatGPTSession {
        refreshInvocationCount += 1
        var refreshed = session
        refreshed.accessToken = "demo-access-token-refreshed-\(refreshInvocationCount)"
        refreshed.acquiredAt = Date()
        refreshed.expiresAt = Date().addingTimeInterval(3600)
        return refreshed
    }

    func signOut(session _: ChatGPTSession?) async {}

    func refreshCount() -> Int {
        refreshInvocationCount
    }
}

private actor UnauthorizedThenSuccessBackend: AgentBackend {
    private var didThrowUnauthorized = false
    private var accessTokensByAttempt: [String] = []

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message: UserMessageRequest,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        tools _: [ToolDefinition],
        session: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        accessTokensByAttempt.append(session.accessToken)
        if !didThrowUnauthorized {
            didThrowUnauthorized = true
            throw AgentRuntimeError.unauthorized("Simulated unauthorized")
        }

        return MockAgentTurnSession(
            thread: thread,
            message: message,
            selectedTool: nil,
            structuredResponseText: nil
        )
    }

    func attemptedAccessTokens() -> [String] {
        accessTokensByAttempt
    }
}

private actor UnauthorizedOnCreateThenSuccessBackend: AgentBackend {
    private var didThrowUnauthorized = false
    private var accessTokensByAttempt: [String] = []

    func createThread(session: ChatGPTSession) async throws -> AgentThread {
        accessTokensByAttempt.append(session.accessToken)
        if !didThrowUnauthorized {
            didThrowUnauthorized = true
            throw AgentRuntimeError.unauthorized("Simulated unauthorized during createThread")
        }

        return AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message _: UserMessageRequest,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        MockAgentTurnSession(
            thread: thread,
            message: .init(text: ""),
            selectedTool: nil,
            structuredResponseText: nil
        )
    }

    func attemptedAccessTokens() -> [String] {
        accessTokensByAttempt
    }
}

private actor ImageReplyAgentBackend: AgentBackend {
    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message _: UserMessageRequest,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> any AgentTurnStreaming {
        ImageReplyTurn(threadID: thread.id)
    }
}

private final class ImageReplyTurn: AgentTurnStreaming, @unchecked Sendable {
    let events: AsyncThrowingStream<AgentBackendEvent, Error>

    init(threadID: String) {
        let image = AgentImageAttachment.png(Data([0x89, 0x50, 0x4E, 0x47]))
        let turn = AgentTurn(id: UUID().uuidString, threadID: threadID)

        events = AsyncThrowingStream { continuation in
            continuation.yield(.turnStarted(turn))
            continuation.yield(
                .assistantMessageCompleted(
                    AgentMessage(
                        threadID: threadID,
                        role: .assistant,
                        text: "",
                        images: [image]
                    )
                )
            )
            continuation.yield(
                .turnCompleted(
                    AgentTurnSummary(
                        threadID: threadID,
                        turnID: turn.id,
                        usage: AgentUsage(inputTokens: 1, outputTokens: 1)
                    )
                )
            )
            continuation.finish()
        }
    }

    func submitToolResult(
        _: ToolResultEnvelope,
        for _: String
    ) async throws {}
}
