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

        _ = try await runtime.send(
            Request(text: "Give me a plan."),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        let resolved = try XCTUnwrap(instructions.last)
        XCTAssertTrue(resolved.contains("Base host instructions."))
        XCTAssertTrue(resolved.contains("Thread Skills:"))
        XCTAssertTrue(resolved.contains("[health_coach: Health Coach]"))
    }

    func testTurnSkillSelectionReplaceAppliesOnlyToCurrentTurn() async throws {
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

        _ = try await runtime.send(
            Request(
                text: "First turn",
                skillSelection: .replace(["health_coach"])
            ),
            in: thread.id
        )

        _ = try await runtime.send(
            Request(text: "Second turn"),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertTrue(instructions[0].contains("[health_coach: Health Coach]"))
        XCTAssertFalse(instructions[1].contains("[health_coach: Health Coach]"))
    }

    func testTurnSkillSelectionAppendKeepsThreadSkillsForCurrentTurn() async throws {
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
                .init(
                    id: "travel_planner",
                    name: "Travel Planner",
                    instructions: "Plan compact itineraries."
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(
            title: "Append Skills",
            skillIDs: ["health_coach"]
        )

        _ = try await runtime.send(
            Request(
                text: "First turn",
                skillSelection: .append(["travel_planner"])
            ),
            in: thread.id
        )

        _ = try await runtime.send(
            Request(text: "Second turn"),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertTrue(instructions[0].contains("[health_coach: Health Coach]"))
        XCTAssertTrue(instructions[0].contains("[travel_planner: Travel Planner]"))
        XCTAssertTrue(instructions[1].contains("[health_coach: Health Coach]"))
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
                    instructions: "Coach users toward their daily step goals."
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(title: "Skill IDs")

        _ = try await runtime.send(
            Request(text: "Before"),
            in: thread.id
        )

        try await runtime.setSkillIDs(["health_coach"], for: thread.id)

        _ = try await runtime.send(
            Request(text: "After"),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertFalse(instructions[0].contains("[health_coach: Health Coach]"))
        XCTAssertTrue(instructions[1].contains("[health_coach: Health Coach]"))
    }

    func testThreadPersonaReplacesBackendBaseInstructions() async throws {
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

        _ = try await runtime.send(
            Request(text: "Need help"),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        let resolved = try XCTUnwrap(instructions.last)
        XCTAssertFalse(resolved.contains("Base host instructions."))
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

        _ = try await runtime.send(
            Request(
                text: "First",
                personaOverride: reviewerOverride
            ),
            in: thread.id
        )

        _ = try await runtime.send(
            Request(text: "Second"),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertFalse(instructions[0].contains("Base host instructions."))
        XCTAssertFalse(instructions[0].contains("[support]"))
        XCTAssertTrue(instructions[0].contains("[reviewer]"))
        XCTAssertFalse(instructions[1].contains("Base host instructions."))
        XCTAssertTrue(instructions[1].contains("[support]"))
        XCTAssertFalse(instructions[1].contains("[reviewer]"))
    }

    func testTurnOverridesReplaceInheritedInstructions() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let supportPersona = AgentPersonaStack(layers: [
            .init(name: "support", instructions: "Act as a support specialist.")
        ])
        let executionPersona = AgentPersonaStack(layers: [
            .init(name: "browser_agent", instructions: "Complete browser tasks deterministically.")
        ])
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
                    id: "thread_skill",
                    name: "Thread Skill",
                    instructions: "Use thread-level behavior."
                ),
                .init(
                    id: "turn_skill",
                    name: "Turn Skill",
                    instructions: "Use request-level behavior."
                ),
            ]
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(
            personaStack: supportPersona,
            skillIDs: ["thread_skill"]
        )

        _ = try await runtime.send(
            Request(
                text: "Run browser automation.",
                executionMode: .ephemeral,
                personaOverride: executionPersona,
                skillSelection: .replace(["turn_skill"])
            ),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        let resolved = try XCTUnwrap(instructions.last)
        XCTAssertFalse(resolved.contains("Base host instructions."))
        XCTAssertFalse(resolved.contains("[support]"))
        XCTAssertFalse(resolved.contains("[thread_skill: Thread Skill]"))
        XCTAssertTrue(resolved.contains("[browser_agent]"))
        XCTAssertTrue(resolved.contains("[turn_skill: Turn Skill]"))
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

        _ = try await runtime.send(
            Request(text: "Before"),
            in: thread.id
        )

        try await runtime.setPersonaStack(plannerPersona, for: thread.id)

        _ = try await runtime.send(
            Request(text: "After"),
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
