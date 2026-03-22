import CodexKit
import XCTest

// MARK: - Memory

extension AgentRuntimeTests {
    func testRuntimeInjectsRelevantMemoryIntoInstructionsAndPreviewMatches() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let store = InMemoryMemoryStore(initialRecords: [
            MemoryRecord(
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                kind: "preference",
                summary: "Health Coach should use direct accountability when the user is behind on steps.",
                evidence: ["The user responds better to blunt coaching than soft encouragement."],
                importance: 0.9,
                tags: ["steps"]
            ),
            MemoryRecord(
                namespace: "demo-assistant",
                scope: "feature:travel-planner",
                kind: "preference",
                summary: "Travel Planner should keep itineraries compact and transit-aware.",
                importance: 0.8
            ),
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
            memory: .init(store: store)
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(
            title: "Memory",
            memoryContext: AgentMemoryContext(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"]
            )
        )

        let preview = try await runtime.memoryQueryPreview(
            for: thread.id,
            request: UserMessageRequest(text: "How should the health coach respond when the user is behind on steps?")
        )
        XCTAssertEqual(preview?.matches.map(\.record.scope.rawValue), ["feature:health-coach"])

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "How should the health coach respond when the user is behind on steps?"),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        let resolved = try XCTUnwrap(instructions.last)
        XCTAssertTrue(resolved.contains("Relevant Memory:"))
        XCTAssertTrue(resolved.contains("Health Coach should use direct accountability when the user is behind on steps."))
        XCTAssertFalse(resolved.contains("Travel Planner should keep itineraries compact and transit-aware."))
    }

    func testRuntimeMemorySelectionCanReplaceOrDisableThreadDefaults() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let store = InMemoryMemoryStore(initialRecords: [
            MemoryRecord(
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                kind: "preference",
                summary: "Health Coach preference."
            ),
            MemoryRecord(
                namespace: "demo-assistant",
                scope: "feature:travel-planner",
                kind: "preference",
                summary: "Travel Planner preference."
            ),
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
            memory: .init(store: store)
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(
            title: "Scoped Memory",
            memoryContext: AgentMemoryContext(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"]
            )
        )

        _ = try await runtime.sendMessage(
            UserMessageRequest(
                text: "Use travel planner memory instead.",
                memorySelection: MemorySelection(
                    mode: .replace,
                    scopes: ["feature:travel-planner"]
                )
            ),
            in: thread.id
        )

        _ = try await runtime.sendMessage(
            UserMessageRequest(
                text: "Now disable memory.",
                memorySelection: MemorySelection(mode: .disable)
            ),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        XCTAssertEqual(instructions.count, 2)
        XCTAssertTrue(instructions[0].contains("Travel Planner preference."))
        XCTAssertFalse(instructions[0].contains("Health Coach preference."))
        XCTAssertFalse(instructions[1].contains("Relevant Memory:"))
    }

    func testRuntimeCanAutomaticallyCaptureMemoriesFromTranscript() async throws {
        let backend = InMemoryAgentBackend(
            structuredResponseText: """
            {"memories":[{"summary":"Health Coach should use direct accountability when step pace is low.","scope":"feature:health-coach","kind":"preference","evidence":["The user asked for blunt reminders when behind on steps."],"importance":0.92,"tags":["steps","tone"],"relatedIDs":["goal-10000"],"dedupeKey":"health-coach-direct-accountability"},{"summary":"Travel Planner should keep itineraries compact and transit-aware.","scope":"feature:travel-planner","kind":"preference","evidence":["The user dislikes sprawling travel plans."],"importance":0.81,"tags":["travel"],"relatedIDs":["travel-style-compact"],"dedupeKey":"travel-planner-compact-itinerary"}]}
            """
        )
        let store = InMemoryMemoryStore()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            memory: .init(store: store)
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(
            title: "Auto Memory",
            memoryContext: AgentMemoryContext(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach", "feature:travel-planner"]
            )
        )

        let capture = try await runtime.captureMemories(
            from: .text("""
            User: Be direct when I am behind on steps.
            User: Keep travel itineraries compact and transit-aware.
            """),
            for: thread.id,
            options: .init(
                defaults: .init(namespace: "demo-assistant"),
                maxMemories: 3
            )
        )

        XCTAssertEqual(capture.records.count, 2)
        XCTAssertEqual(capture.records.map(\.scope.rawValue).sorted(), ["feature:health-coach", "feature:travel-planner"])

        let stored = try await store.query(
            MemoryQuery(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach", "feature:travel-planner"],
                text: "direct steps transit itinerary",
                limit: 10,
                maxCharacters: 1000
            )
        )
        XCTAssertEqual(stored.matches.count, 2)

        let formats = await backend.receivedResponseFormats()
        XCTAssertEqual(formats.last??.name, "memory_extraction_batch")
    }

    func testRuntimeCanAutomaticallyCaptureMemoryAfterSuccessfulTurn() async throws {
        let backend = InMemoryAgentBackend(
            structuredResponseText: """
            {"memories":[{"summary":"Health Coach should use direct accountability when the user falls behind on steps.","scope":"feature:health-coach","kind":"preference","evidence":["The user said blunt reminders work better than soft encouragement."],"importance":0.94,"tags":["steps","tone"],"relatedIDs":["goal-10000"],"dedupeKey":"health-coach-auto-capture"}]}
            """
        )
        let store = InMemoryMemoryStore()
        let observer = RecordingMemoryObserver()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            memory: .init(
                store: store,
                observer: observer,
                automaticCapturePolicy: .init(
                    source: .lastTurn,
                    options: .init(
                        defaults: .init(namespace: "demo-assistant"),
                        maxMemories: 2
                    )
                )
            )
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(
            title: "Auto Policy",
            memoryContext: AgentMemoryContext(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"]
            )
        )

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "If I am behind on steps, be direct and blunt with me."),
            in: thread.id
        )

        let stored = try await store.query(
            MemoryQuery(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"],
                text: "direct blunt steps",
                limit: 10,
                maxCharacters: 1000
            )
        )
        XCTAssertEqual(stored.matches.count, 1)
        XCTAssertEqual(stored.matches[0].record.dedupeKey, "health-coach-auto-capture")

        let formats = await backend.receivedResponseFormats()
        XCTAssertEqual(formats.count, 2)
        XCTAssertNil(formats.first!)
        XCTAssertEqual(formats.last??.name, "memory_extraction_batch")

        let events = await observer.events()
        let captureEvents = events.compactMap { event -> (String, String?, Int?)? in
            switch event {
            case let .captureStarted(threadID, sourceDescription):
                return (threadID, sourceDescription, nil)
            case let .captureSucceeded(threadID, result):
                return (threadID, nil, result.records.count)
            default:
                return nil
            }
        }

        XCTAssertEqual(captureEvents.count, 2)
        XCTAssertEqual(captureEvents[0].0, thread.id)
        XCTAssertEqual(captureEvents[0].1, "last_turn")
        XCTAssertEqual(captureEvents[1].0, thread.id)
        XCTAssertEqual(captureEvents[1].2, 1)
    }

    func testRuntimeGracefullyDegradesWhenMemoryStoreFails() async throws {
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
            memory: .init(store: ThrowingMemoryStore())
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(
            title: "Graceful",
            memoryContext: AgentMemoryContext(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"]
            )
        )

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "This should still work."),
            in: thread.id
        )

        let instructions = await backend.receivedInstructions()
        let resolved = try XCTUnwrap(instructions.last)
        XCTAssertFalse(resolved.contains("Relevant Memory:"))
    }

    func testRuntimeReportsMemoryObservationEvents() async throws {
        let backend = InMemoryAgentBackend(
            baseInstructions: "Base host instructions."
        )
        let store = InMemoryMemoryStore(initialRecords: [
            MemoryRecord(
                namespace: "demo-assistant",
                scope: "feature:health-coach",
                kind: "preference",
                summary: "Observed memory."
            ),
        ])
        let observer = RecordingMemoryObserver()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            memory: .init(
                store: store,
                observer: observer
            )
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(
            title: "Observed",
            memoryContext: AgentMemoryContext(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"]
            )
        )

        _ = try await runtime.sendMessage(
            UserMessageRequest(text: "Use memory."),
            in: thread.id
        )

        let events = await observer.events()
        XCTAssertEqual(events.count, 2)
        guard case let .queryStarted(startedQuery) = events[0] else {
            return XCTFail("Expected queryStarted event.")
        }
        XCTAssertEqual(startedQuery.namespace, "demo-assistant")
        guard case let .querySucceeded(_, result) = events[1] else {
            return XCTFail("Expected querySucceeded event.")
        }
        XCTAssertEqual(result.matches.count, 1)
    }

    func testRuntimeProvidesThreadAwareMemoryWriterDefaults() async throws {
        let store = InMemoryMemoryStore()
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore(),
            memory: .init(store: store)
        ))

        _ = try await runtime.restore()
        _ = try await runtime.signIn()

        let thread = try await runtime.createThread(
            title: "Thread Memory Writer",
            memoryContext: AgentMemoryContext(
                namespace: "demo-assistant",
                scopes: ["feature:health-coach"],
                kinds: ["preference"],
                tags: ["steps"],
                relatedIDs: ["goal-10000"]
            )
        )

        let writer = try await runtime.memoryWriter(for: thread.id)
        let record = try await writer.put(
            MemoryDraft(
                summary: "The demo user responds better to direct step reminders."
            )
        )

        XCTAssertEqual(record.namespace, "demo-assistant")
        XCTAssertEqual(record.scope, "feature:health-coach")
        XCTAssertEqual(record.kind, "preference")
        XCTAssertEqual(record.tags, ["steps"])
        XCTAssertEqual(record.relatedIDs, ["goal-10000"])
    }

    func testRuntimeMemoryWriterThrowsWhenMemoryIsNotConfigured() async throws {
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

        await XCTAssertThrowsErrorAsync(try await runtime.memoryWriter()) { error in
            XCTAssertEqual(error as? AgentRuntimeError, .memoryNotConfigured())
        }
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

    func testThreadMemoryContextPersistsAcrossRestore() async throws {
        let runtimeStore = InMemoryRuntimeStateStore()
        let memoryContext = AgentMemoryContext(
            namespace: "demo-assistant",
            scopes: ["feature:health-coach"],
            kinds: ["preference"],
            tags: ["steps"],
            relatedIDs: ["goal-10000"],
            readBudget: .init(maxItems: 3, maxCharacters: 500)
        )
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

        let thread = try await runtime.createThread(
            title: "Memory Context",
            memoryContext: memoryContext
        )

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

        let restoredThreads = try await restoredRuntime.restore().threads
        let restoredContext = try await restoredRuntime.memoryContext(for: thread.id)

        XCTAssertEqual(restoredContext, memoryContext)
        XCTAssertEqual(restoredThreads.first?.memoryContext, memoryContext)
    }
}
