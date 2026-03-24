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

}
