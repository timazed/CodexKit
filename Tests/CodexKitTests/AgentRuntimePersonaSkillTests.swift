import CodexKit
import XCTest

// MARK: - Personas And Skills

extension AgentRuntimeTests {
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
            title: "Skills",
            skillIDs: ["health_coach"]
        )

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "Give me a plan."),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        let resolved = try XCTUnwrap(instructions.last)
        XCTAssertTrue(resolved.contains("Base host instructions."))
        XCTAssertTrue(resolved.contains("Thread Skills:"))
        XCTAssertTrue(resolved.contains("[health_coach: Health Coach]"))
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
                    id: "health_coach",
                    name: "Health Coach",
                    instructions: "Coach users toward their daily step goals."
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Turn Skills")

        _ = try await runtime.sendMessage(
            UserMessageRequest(
                text: "First turn",
                skillOverrideIDs: ["health_coach"]
            ),
            in: thread.id
        )

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "Second turn"),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertTrue(instructions[0].contains("[health_coach: Health Coach]"))
        XCTAssertFalse(instructions[1].contains("[health_coach: Health Coach]"))
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
                    instructions: "Coach users toward their daily step goals."
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Skill IDs")

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "Before"),
            in: thread.id
        )

        try await runtime.setSkillIDs(["health_coach"], for: thread.id)

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "After"),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertFalse(instructions[0].contains("[health_coach: Health Coach]"))
        XCTAssertTrue(instructions[1].contains("[health_coach: Health Coach]"))
    }

    func testThreadPersonaUsesBackendBaseInstructionsWhenRuntimeBaseIsUnset() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let supportPersona = AgentPersonaStack(layers: [
            .init(name: "support", instructions: "Act as a support specialist.")
        ])
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

        let thread = try await runtime.createThread(personaStack: supportPersona)

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "Need help"),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        let resolved = try XCTUnwrap(instructions.last)
        XCTAssertTrue(resolved.contains("Base host instructions."))
        XCTAssertTrue(resolved.contains("[support]"))
    }

    func testTurnPersonaOverrideAppliesOnlyToCurrentTurn() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let supportPersona = AgentPersonaStack(layers: [
            .init(name: "support", instructions: "Act as a support specialist.")
        ])
        let reviewerOverride = AgentPersonaStack(layers: [
            .init(name: "reviewer", instructions: "Call out risks first.")
        ])
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

        let thread = try await runtime.createThread(personaStack: supportPersona)

        _ = try await runtime.sendMessage(
            UserMessageRequest(
                text: "First",
                personaOverride: reviewerOverride
            ),
            in: thread.id
        )

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "Second"),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertTrue(instructions[0].contains("[reviewer]"))
        XCTAssertTrue(instructions[1].contains("[support]"))
        XCTAssertFalse(instructions[1].contains("[reviewer]"))
    }

    func testSetPersonaStackAffectsFutureTurnsOnly() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let supportPersona = AgentPersonaStack(layers: [
            .init(name: "support", instructions: "Act as a support specialist.")
        ])
        let plannerPersona = AgentPersonaStack(layers: [
            .init(name: "planner", instructions: "Focus on sequencing and tradeoffs.")
        ])
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

        let thread = try await runtime.createThread(personaStack: supportPersona)

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "Before"),
            in: thread.id
        )

        try await runtime.setPersonaStack(plannerPersona, for: thread.id)

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "After"),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertTrue(instructions[0].contains("[support]"))
        XCTAssertTrue(instructions[1].contains("[planner]"))
        XCTAssertFalse(instructions[1].contains("[support]"))
    }

    func testThreadPersonaStackPersistsAcrossRestore() async throws {
        let runtimeStore = InMemoryRuntimeStateStore()
        let supportPersona = AgentPersonaStack(layers: [
            .init(name: "support", instructions: "Act as a support specialist.")
        ])
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: runtimeStore
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(personaStack: supportPersona)

        let restoredRuntime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: runtimeStore
        ))

        let restoredState = try await restoredRuntime.restore()
        let restoredThread = try XCTUnwrap(restoredState.threads.first(where: { $0.id == thread.id }))
        XCTAssertEqual(restoredThread.personaStack, supportPersona)
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
                AgentPersonaStack(layers: [.init(name: "missing", instructions: "nope")]),
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
          "id": "travel_planner",
          "name": "Travel Planner",
          "instructions": "Keep itineraries compact and transit-aware."
        }
        """
        let skillFile = try temporaryFile(
            with: skillJSON,
            pathExtension: "json"
        )

        _ = try await runtime.registerSkill(
            from: .file(skillFile)
        )

        let thread = try await runtime.createThread(
            title: "Travel",
            skillIDs: ["travel_planner"]
        )

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "Plan my day"),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        let resolved = try XCTUnwrap(instructions.last)
        XCTAssertTrue(resolved.contains("[travel_planner: Travel Planner]"))
    }
}
