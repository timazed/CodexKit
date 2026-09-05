import CodexKit
@testable import CodexKitRealm
@testable import CodexKitSQLite
import XCTest

extension AgentRuntimeTests {
    func testMemoryPlacementOverridesSurviveCodableRoundTrips() throws {
        let context = AgentMemoryContext(
            namespace: "test-agent",
            scopes: ["confirmed-learning"],
            instructionPlacement: .beforeSkills
        )
        let selection = MemorySelection(
            mode: .append,
            scopes: ["request-learning"],
            instructionPlacement: .beforePersonas
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(
            try decoder.decode(AgentMemoryContext.self, from: encoder.encode(context)),
            context
        )
        XCTAssertEqual(
            try decoder.decode(MemorySelection.self, from: encoder.encode(selection)),
            selection
        )
    }

    func testMemoryInstructionPlacementDefaultsAfterSkills() async throws {
        let backend = InMemoryAgentBackend(baseInstructions: "BASE")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Default placement",
            skillIDs: ["thread_skill"],
            memoryContext: testMemoryContext
        )
        let request = Request(
            text: "confirmed learning",
            skillSelection: .append(["turn_skill"])
        )

        let preview = try await runtime.resolvedInstructionsPreviewDetails(
            for: thread.id,
            request: request
        )

        XCTAssertEqual(
            preview.instructions,
            "BASE\n\nTHREAD SKILL\n\nTURN SKILL\n\nMEMORY"
        )
        XCTAssertEqual(preview.memory?.placement, .afterSkills)

        _ = try await runtime.send(request, in: thread.id)
        let receivedInstructions = await backend.receivedInstructions()
        XCTAssertEqual(receivedInstructions.last, preview.instructions)
    }

    func testMemoryInstructionPlacementBeforePersonasPreservesPersonaBehavior() async throws {
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            placement: .beforePersonas
        )
        let thread = try await runtime.createThread(
            title: "Before personas",
            personaStack: AgentPersonaStack(layers: [
                .init(name: "thread", instructions: "THREAD PERSONA"),
            ]),
            skillIDs: ["thread_skill"],
            memoryContext: testMemoryContext
        )

        let preview = try await runtime.resolvedInstructionsPreview(
            for: thread.id,
            request: Request(text: "confirmed learning")
        )

        XCTAssertEqual(preview, "MEMORY\n\nTHREAD PERSONA\n\nTHREAD SKILL")
        XCTAssertFalse(preview.contains("BASE"))
    }

    func testMemoryInstructionPlacementBeforeSkillsKeepsSkillsAuthoritative() async throws {
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            placement: .beforeSkills
        )
        let thread = try await runtime.createThread(
            title: "Before skills",
            personaStack: AgentPersonaStack(layers: [
                .init(name: "thread", instructions: "THREAD PERSONA"),
            ]),
            skillIDs: ["thread_skill"],
            memoryContext: testMemoryContext
        )
        let request = Request(
            text: "confirmed learning",
            skillSelection: .append(["turn_skill"])
        )

        let preview = try await runtime.resolvedInstructionsPreview(
            for: thread.id,
            request: request
        )

        XCTAssertEqual(
            preview,
            "THREAD PERSONA\n\nMEMORY\n\nTHREAD SKILL\n\nTURN SKILL"
        )
    }

    func testBeforeSkillsPreservesExistingTurnPersonaOverrideOrder() async throws {
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            placement: .beforeSkills
        )
        let thread = try await runtime.createThread(
            title: "Override ordering",
            personaStack: AgentPersonaStack(layers: [
                .init(name: "thread", instructions: "THREAD PERSONA"),
            ]),
            skillIDs: ["thread_skill"],
            memoryContext: testMemoryContext
        )
        let request = Request(
            text: "confirmed learning",
            personaOverride: AgentPersonaStack(layers: [
                .init(name: "turn", instructions: "TURN PERSONA"),
            ]),
            skillSelection: .append(["turn_skill"])
        )

        let preview = try await runtime.resolvedInstructionsPreview(
            for: thread.id,
            request: request
        )

        XCTAssertEqual(
            preview,
            "MEMORY\n\nTHREAD SKILL\n\nTURN PERSONA\n\nTURN SKILL"
        )
    }

    func testTurnSelectionCanOverrideConfiguredMemoryPlacement() async throws {
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            placement: .afterSkills
        )
        let thread = try await runtime.createThread(
            title: "Turn placement",
            skillIDs: ["thread_skill"],
            memoryContext: testMemoryContext
        )
        let request = Request(
            text: "confirmed learning",
            memorySelection: MemorySelection(instructionPlacement: .beforeSkills)
        )

        let preview = try await runtime.resolvedInstructionsPreviewDetails(
            for: thread.id,
            request: request
        )

        XCTAssertEqual(preview.instructions, "BASE\n\nMEMORY\n\nTHREAD SKILL")
        XCTAssertEqual(preview.memory?.placement, .beforeSkills)
    }

    func testThreadMemoryPlacementOverridesRuntimeDefault() async throws {
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            placement: .afterSkills
        )
        let thread = try await runtime.createThread(
            title: "Thread placement",
            skillIDs: ["thread_skill"],
            memoryContext: AgentMemoryContext(
                namespace: "test-agent",
                scopes: ["confirmed-learning"],
                instructionPlacement: .beforeSkills
            )
        )

        let preview = try await runtime.resolvedInstructionsPreviewDetails(
            for: thread.id,
            request: Request(text: "confirmed learning")
        )

        XCTAssertEqual(preview.instructions, "BASE\n\nMEMORY\n\nTHREAD SKILL")
        XCTAssertEqual(preview.memory?.placement, .beforeSkills)
    }

    func testInvalidClientRequestIDFailsBeforeStartingTurn() async throws {
        let backend = InMemoryAgentBackend(baseInstructions: "BASE")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Invalid correlation",
            memoryContext: testMemoryContext
        )

        do {
            _ = try await runtime.send(
                Request(text: "confirmed learning").correlated(with: "  \n"),
                in: thread.id
            )
            XCTFail("Expected an invalid correlation identifier error.")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "invalid_client_request_id")
        }

        let receivedInstructions = await backend.receivedInstructions()
        XCTAssertTrue(receivedInstructions.isEmpty)
    }

    func testTypedContextIsNotImplicitMemorySearchText() async throws {
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: DefaultMemoryPromptRenderer(),
            records: [
                MemoryRecord(
                    id: "heavy-track",
                    namespace: "test-agent",
                    scope: "confirmed-learning",
                    category: "learning",
                    summary: "Heavy track sprint pattern",
                    importance: 0.9
                ),
            ]
        )
        let thread = try await runtime.createThread(
            title: "Explicit query text",
            memoryContext: testMemoryContext
        )
        let implicit = try Request(
            text: "Analyse the supplied race.",
            context: MemorySearchFixture(surface: "heavy track sprint")
        )
        let explicit = try Request(
            text: "Analyse the supplied race.",
            context: MemorySearchFixture(surface: "heavy track sprint"),
            memorySelection: MemorySelection(text: "heavy track sprint")
        )

        let implicitPreview = try await runtime.resolvedInstructionsPreviewDetails(
            for: thread.id,
            request: implicit
        )
        let explicitPreview = try await runtime.resolvedInstructionsPreviewDetails(
            for: thread.id,
            request: explicit
        )

        XCTAssertNil(implicitPreview.memory)
        XCTAssertEqual(explicitPreview.memory?.includedRecordIDs, ["heavy-track"])
        XCTAssertEqual(explicitPreview.memory?.query.text, "heavy track sprint")
    }

    func testMemoryApplicationSnapshotUsesRendererMetadataAndCompletedTurnID() async throws {
        let observer = RecordingMemoryObserver()
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: SelectiveMemoryRenderer(),
            observer: observer,
            placement: .beforeSkills,
            records: testMemoryRecords
        )
        let thread = try await runtime.createThread(
            title: "Applied memory",
            skillIDs: ["thread_skill"],
            memoryContext: testMemoryContext
        )
        let request = Request(text: "confirmed learning")
            .correlated(with: "assessment-123")

        let preview = try await runtime.resolvedInstructionsPreviewDetails(
            for: thread.id,
            request: request
        )
        XCTAssertEqual(preview.memory?.includedRecordIDs, ["memory-2"])
        let previewApplications = await observer.applications()
        XCTAssertTrue(previewApplications.isEmpty)

        var completedTurnID: String?
        let stream = try await runtime.stream(request, in: thread.id)
        for try await event in stream {
            if case let .turnCompleted(summary) = event {
                completedTurnID = summary.turnID
            }
        }

        let applications = await observer.applications(waitingFor: 1)
        let application = try XCTUnwrap(applications.first)
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(application.threadID, thread.id)
        XCTAssertEqual(application.turnID, completedTurnID)
        XCTAssertEqual(application.clientRequestID, "assessment-123")
        XCTAssertEqual(application.activeSkillIDs, ["thread_skill"])
        XCTAssertEqual(application.compiledInstructionsSHA256.count, 64)
        XCTAssertEqual(application.includedRecordIDs, ["memory-2"])
        XCTAssertEqual(application.renderedInstructions, "MEMORY")
        XCTAssertEqual(application.placement, .beforeSkills)
        XCTAssertEqual(application.result.matches.count, 2)
        let durable = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertEqual(durable, applications)
    }

    func testMemoryApplicationFreezesConfigurationUsedToStartTurn() async throws {
        let backend = DelayedBeginTurnBackend()
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Frozen attribution configuration",
            configuration: AgentThreadConfiguration(
                model: "model-used-for-turn",
                reasoningEffort: .high
            ),
            memoryContext: testMemoryContext
        )
        let sendTask = Task {
            try await runtime.send(
                Request(text: "confirmed learning"),
                in: thread.id
            )
        }

        await backend.waitForBeginTurnStart()
        try await runtime.updateThreadConfiguration(
            AgentThreadConfiguration(
                model: "model-for-next-turn",
                reasoningEffort: .low
            ),
            for: thread.id
        )
        await backend.releaseBeginTurn()
        _ = try await sendTask.value

        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        let application = try XCTUnwrap(applications.first)
        XCTAssertEqual(application.model, "model-used-for-turn")
        XCTAssertEqual(application.reasoningEffort, .high)
    }

    func testOversizedRenderedMemoryIsSkippedBeforeBackendExecution() async throws {
        let backend = InMemoryAgentBackend(baseInstructions: "BASE")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: OversizedMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Bound rendered attribution",
            memoryContext: testMemoryContext
        )

        let result = try await runtime.sendWithSummary(
            Request(text: "confirmed learning"),
            in: thread.id
        )

        let receivedInstructions = await backend.receivedInstructions()
        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertEqual(receivedInstructions.last, "BASE")
        XCTAssertTrue(applications.isEmpty)
        XCTAssertEqual(result.memoryApplication.omissionReason, .rejected)
    }

    func testOversizedMemoryResultIsSkippedBeforeBackendExecution() async throws {
        let largeAttribute = String(repeating: "x", count: 120_000)
        let records = (0 ..< 40).map { index in
            MemoryRecord(
                id: "large-memory-\(index)",
                namespace: "test-agent",
                scope: "confirmed-learning",
                category: "learning",
                summary: "Confirmed learning \(index)",
                importance: 0.9,
                attributes: .object(["blob": .string(largeAttribute)])
            )
        }
        let backend = InMemoryAgentBackend(baseInstructions: "BASE")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: DefaultMemoryPromptRenderer(),
            records: records,
            readBudget: MemoryReadBudget(maxItems: 40, maxCharacters: 100_000)
        )
        let thread = try await runtime.createThread(
            title: "Bound result attribution",
            memoryContext: testMemoryContext
        )

        _ = try await runtime.send(
            Request(text: "confirmed learning"),
            in: thread.id
        )

        let receivedInstructions = await backend.receivedInstructions()
        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertEqual(receivedInstructions.last, "BASE")
        XCTAssertTrue(applications.isEmpty)
    }

    func testPreflightIdentifierReservationBoundsValidatedJSONEncoding() throws {
        let reserved = AgentStoreLimits.maximumEncodedIdentifierPlaceholder
        let candidates = [
            String(repeating: "a", count: AgentStoreLimits.maximumIdentifierByteCount),
            String(repeating: "\"", count: AgentStoreLimits.maximumIdentifierByteCount),
            String(repeating: "\\", count: AgentStoreLimits.maximumIdentifierByteCount),
            String(repeating: "\u{0}", count: AgentStoreLimits.maximumIdentifierByteCount),
            String(
                repeating: "😀",
                count: AgentStoreLimits.maximumIdentifierByteCount / 4
            ),
        ]
        let encoder = JSONEncoder()
        let reservedSize = try encoder.encode(["identifier": reserved]).count

        XCTAssertEqual(
            reserved.utf8.count,
            AgentStoreLimits.maximumIdentifierByteCount
        )
        for candidate in candidates {
            XCTAssertLessThanOrEqual(
                try encoder.encode(["identifier": candidate]).count,
                reservedSize
            )
        }
    }

    func testRendererOutputOverConfiguredBudgetIsSkippedBeforeBackendExecution() async throws {
        let backend = InMemoryAgentBackend(baseInstructions: "BASE")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: FixedMemoryRenderer(instructions: "123456789"),
            readBudget: MemoryReadBudget(maxItems: 1, maxCharacters: 8)
        )
        let thread = try await runtime.createThread(
            title: "Bound renderer budget",
            memoryContext: testMemoryContext
        )

        _ = try await runtime.send(
            Request(text: "confirmed learning"),
            in: thread.id
        )

        let receivedInstructions = await backend.receivedInstructions()
        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertEqual(receivedInstructions.last, "BASE")
        XCTAssertTrue(applications.isEmpty)
    }

    func testExtremeNegativeCharacterBudgetSafelySkipsMemory() async throws {
        let backend = InMemoryAgentBackend(baseInstructions: "BASE")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer(),
            readBudget: MemoryReadBudget(maxItems: 1, maxCharacters: .min)
        )
        let thread = try await runtime.createThread(
            title: "Saturate negative budget",
            memoryContext: testMemoryContext
        )

        _ = try await runtime.send(
            Request(text: "confirmed learning"),
            in: thread.id
        )

        let receivedInstructions = await backend.receivedInstructions()
        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertEqual(receivedInstructions.last, "BASE")
        XCTAssertTrue(applications.isEmpty)
    }

    func testInvalidReadBudgetIsRejectedBeforeCallingCustomStore() async throws {
        let store = ControlledMemoryStore(behavior: .emptyResult)
        let backend = InMemoryAgentBackend(baseInstructions: "BASE")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer(),
            memoryStore: store,
            readBudget: MemoryReadBudget(maxItems: .max, maxCharacters: 100)
        )
        let thread = try await runtime.createThread(
            title: "Reject invalid query before store",
            memoryContext: testMemoryContext
        )

        _ = try await runtime.send(
            Request(text: "confirmed learning"),
            in: thread.id
        )

        let receivedInstructions = await backend.receivedInstructions()
        let queryInvocationCount = await store.queryInvocationCount()
        XCTAssertEqual(queryInvocationCount, 0)
        XCTAssertEqual(receivedInstructions.last, "BASE")
    }

    func testInvalidCustomStoreResultIsRejectedBeforeRendering() async throws {
        let store = ControlledMemoryStore(behavior: .oversizedResult)
        let recorder = RenderInvocationRecorder()
        let backend = InMemoryAgentBackend(baseInstructions: "BASE")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: RecordingMemoryRenderer(recorder: recorder),
            memoryStore: store,
            readBudget: MemoryReadBudget(maxItems: 1, maxCharacters: 100)
        )
        let thread = try await runtime.createThread(
            title: "Reject invalid store result",
            memoryContext: testMemoryContext
        )

        _ = try await runtime.send(
            Request(text: "confirmed learning"),
            in: thread.id
        )

        let receivedInstructions = await backend.receivedInstructions()
        XCTAssertEqual(recorder.invocationCount(), 0)
        XCTAssertEqual(receivedInstructions.last, "BASE")
    }

    func testOutOfScopeCustomStoreResultIsRejectedBeforeRendering() async throws {
        let store = ControlledMemoryStore(behavior: .outOfScopeResult)
        let recorder = RenderInvocationRecorder()
        let backend = InMemoryAgentBackend(baseInstructions: "BASE")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: RecordingMemoryRenderer(recorder: recorder),
            memoryStore: store,
            readBudget: MemoryReadBudget(maxItems: 1, maxCharacters: 100)
        )
        let thread = try await runtime.createThread(
            title: "Reject out-of-scope store result",
            memoryContext: testMemoryContext
        )

        _ = try await runtime.send(
            Request(text: "confirmed learning"),
            in: thread.id
        )

        let receivedInstructions = await backend.receivedInstructions()
        XCTAssertEqual(recorder.invocationCount(), 0)
        XCTAssertEqual(receivedInstructions.last, "BASE")
    }

    func testEmptyCustomStoreResultWithCursorIsRejectedBeforeRendering() async throws {
        let store = ControlledMemoryStore(behavior: .cursorWithoutMatch)
        let recorder = RenderInvocationRecorder()
        let backend = InMemoryAgentBackend(baseInstructions: "BASE")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: RecordingMemoryRenderer(recorder: recorder),
            memoryStore: store
        )
        let thread = try await runtime.createThread(
            title: "Reject cursor without match",
            memoryContext: testMemoryContext
        )

        _ = try await runtime.send(
            Request(text: "confirmed learning"),
            in: thread.id
        )

        let receivedInstructions = await backend.receivedInstructions()
        XCTAssertEqual(recorder.invocationCount(), 0)
        XCTAssertEqual(receivedInstructions.last, "BASE")
    }

    func testOversizedRendererMetadataIsConservativelyUnattributed() async throws {
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: OversizedMetadataMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Bound renderer metadata",
            memoryContext: testMemoryContext
        )

        _ = try await runtime.send(
            Request(text: "confirmed learning"),
            in: thread.id
        )

        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertEqual(applications.first?.includedRecordIDs, [])
    }

    func testMemoryQueryCancellationStopsBeforeBackendExecution() async throws {
        let store = ControlledMemoryStore(behavior: .waitForCancellation)
        let observer = RecordingMemoryObserver()
        let backend = InMemoryAgentBackend(baseInstructions: "BASE")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer(),
            observer: observer,
            memoryStore: store
        )
        let thread = try await runtime.createThread(
            title: "Cancel memory query",
            memoryContext: testMemoryContext
        )
        let sendTask = Task {
            try await runtime.send(
                Request(text: "confirmed learning"),
                in: thread.id
            )
        }

        await store.waitUntilQueryStarts()
        sendTask.cancel()
        do {
            _ = try await sendTask.value
            XCTFail("Expected memory-query cancellation to propagate.")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        let receivedInstructions = await backend.receivedInstructions()
        let applications = await observer.applications()
        XCTAssertTrue(receivedInstructions.isEmpty)
        XCTAssertTrue(applications.isEmpty)
    }

    func testCancelledNonCooperativeCompletionDoesNotCreateUnstructuredAttribution() async throws {
        let backend = NonCooperativeCompletionBackend(emitsStructuredOutput: false)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Cancel non-cooperative completion",
            memoryContext: testMemoryContext
        )
        let sendTask = Task {
            try await runtime.send(
                Request(text: "confirmed learning"),
                in: thread.id
            )
        }

        await backend.waitUntilTurnStarts()
        sendTask.cancel()
        await backend.release()
        do {
            _ = try await sendTask.value
            XCTFail("Expected cancellation before backend completion to propagate.")
        } catch is CancellationError {
            // Expected.
        }

        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertTrue(applications.isEmpty)
    }

    func testCancelledNonCooperativeCompletionDoesNotCreateStructuredAttribution() async throws {
        let backend = NonCooperativeCompletionBackend(emitsStructuredOutput: true)
        let consumerSignal = TurnStartSignal()
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Cancel structured non-cooperative completion",
            memoryContext: testMemoryContext
        )
        let sendTask = Task {
            let stream = try await runtime.stream(
                Request(text: "confirmed learning"),
                in: thread.id,
                response: ShippingReplyDraft.self
            )
            for try await event in stream {
                if case .turnStarted = event {
                    await consumerSignal.markStarted()
                    try await Task.sleep(for: .seconds(60))
                }
            }
        }

        await consumerSignal.waitUntilStarted()
        sendTask.cancel()
        do {
            try await sendTask.value
            XCTFail("Expected structured cancellation before completion to propagate.")
        } catch is CancellationError {
            // Expected.
        }
        await backend.release()

        for _ in 0 ..< 100 {
            let summary = try await runtime.fetchThreadSummary(id: thread.id)
            if summary.latestTurnStatus == .interrupted {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let summary = try await runtime.fetchThreadSummary(id: thread.id)
        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertEqual(summary.latestTurnStatus, .interrupted)
        XCTAssertTrue(applications.isEmpty)
    }

    func testStructuredStreamReportsMemoryApplicationOnce() async throws {
        let observer = RecordingMemoryObserver()
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            observer: observer
        )
        let thread = try await runtime.createThread(
            title: "Structured application",
            memoryContext: testMemoryContext
        )

        var completedTurnID: String?
        let stream = try await runtime.stream(
            Request(text: "confirmed learning"),
            in: thread.id,
            response: ShippingReplyDraft.self
        )
        for try await event in stream {
            if case let .turnCompleted(summary) = event {
                completedTurnID = summary.turnID
            }
        }

        let applications = await observer.applications(waitingFor: 1)
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(applications.first?.turnID, completedTurnID)
    }

    func testMismatchedCompletionTurnIDRejectsUnstructuredAttribution() async throws {
        let backend = MismatchedCompletionBackend(emitsStructuredOutput: false)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Reject mismatched completion",
            memoryContext: testMemoryContext
        )

        do {
            _ = try await runtime.send(
                Request(text: "confirmed learning"),
                in: thread.id
            )
            XCTFail("Expected mismatched completion to fail.")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "invalid_turn_completion")
        }

        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertTrue(applications.isEmpty)
    }

    func testMismatchedTurnStartThreadRejectsAttribution() async throws {
        let backend = MismatchedCompletionBackend(
            emitsStructuredOutput: false,
            mismatchesStartedThread: true
        )
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Reject mismatched turn start",
            memoryContext: testMemoryContext
        )

        do {
            _ = try await runtime.send(
                Request(text: "confirmed learning"),
                in: thread.id
            )
            XCTFail("Expected mismatched turn start to fail.")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "invalid_turn_start")
        }

        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertTrue(applications.isEmpty)
    }

    func testOversizedTurnStartIDRejectsAttribution() async throws {
        let backend = MismatchedCompletionBackend(
            emitsStructuredOutput: false,
            startedTurnID: String(
                repeating: "x",
                count: AgentStoreLimits.maximumIdentifierByteCount + 1
            )
        )
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Reject oversized turn start",
            memoryContext: testMemoryContext
        )

        do {
            _ = try await runtime.send(
                Request(text: "confirmed learning"),
                in: thread.id
            )
            XCTFail("Expected oversized turn ID to fail.")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "invalid_turn_start")
        }

        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertTrue(applications.isEmpty)
    }

    func testMismatchedCompletionTurnIDRejectsStructuredAttribution() async throws {
        let backend = MismatchedCompletionBackend(emitsStructuredOutput: true)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Reject structured mismatched completion",
            memoryContext: testMemoryContext
        )

        do {
            let stream = try await runtime.stream(
                Request(text: "confirmed learning"),
                in: thread.id,
                response: ShippingReplyDraft.self
            )
            for try await _ in stream {}
            XCTFail("Expected mismatched structured completion to fail.")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "invalid_turn_completion")
        }

        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertTrue(applications.isEmpty)
    }

    func testCompletionIsTerminalForUnstructuredAttribution() async throws {
        let backend = AdversarialTurnBackend(behavior: .completionThenFailure(structured: false))
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Terminal unstructured completion",
            memoryContext: testMemoryContext
        )

        let result = try await runtime.sendWithSummary(
            Request(text: "confirmed learning"),
            in: thread.id
        )
        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        let summary = try await runtime.fetchThreadSummary(id: thread.id)

        XCTAssertEqual(result.value, "Completed")
        XCTAssertEqual(applications.map(\.turnID), [result.summary.turnID])
        XCTAssertEqual(summary.latestTurnStatus, .completed)
    }

    func testCompletionIsTerminalForStructuredAttribution() async throws {
        let backend = AdversarialTurnBackend(behavior: .completionThenFailure(structured: true))
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Terminal structured completion",
            memoryContext: testMemoryContext
        )

        let result = try await runtime.sendWithSummary(
            Request(text: "confirmed learning"),
            in: thread.id,
            response: ShippingReplyDraft.self
        )
        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        let summary = try await runtime.fetchThreadSummary(id: thread.id)

        XCTAssertEqual(result.value.reply, "Structured echo")
        XCTAssertEqual(applications.map(\.turnID), [result.summary.turnID])
        XCTAssertEqual(summary.latestTurnStatus, .completed)
    }

    func testCrossThreadAssistantMessageCannotBePairedWithCurrentAttribution() async throws {
        let backend = AdversarialTurnBackend(behavior: .mismatchedAssistantThread)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Reject cross-thread assistant",
            memoryContext: testMemoryContext
        )

        do {
            _ = try await runtime.sendWithSummary(
                Request(text: "confirmed learning"),
                in: thread.id
            )
            XCTFail("Expected the cross-thread assistant message to fail.")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "invalid_backend_turn_event")
        }

        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertTrue(applications.isEmpty)
    }

    func testCrossTurnStructuredDeltaIsRejected() async throws {
        let backend = AdversarialTurnBackend(behavior: .mismatchedDeltaTurn)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Reject cross-turn delta",
            memoryContext: testMemoryContext
        )

        do {
            let stream = try await runtime.stream(
                Request(text: "confirmed learning"),
                in: thread.id,
                response: ShippingReplyDraft.self
            )
            for try await _ in stream {}
            XCTFail("Expected the cross-turn delta to fail.")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "invalid_backend_turn_event")
        }

        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertTrue(applications.isEmpty)
    }

    func testCrossTurnToolInvocationIsRejectedBeforeExecution() async throws {
        let backend = AdversarialTurnBackend(behavior: .mismatchedToolTurn)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Reject cross-turn tool",
            memoryContext: testMemoryContext
        )

        do {
            _ = try await runtime.send(
                Request(text: "confirmed learning"),
                in: thread.id
            )
            XCTFail("Expected the cross-turn tool invocation to fail.")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "invalid_backend_turn_event")
        }
    }

    func testCrossThreadProviderContextIsRejected() async throws {
        let backend = AdversarialTurnBackend(behavior: .mismatchedProviderThread)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(title: "Reject provider context")

        do {
            _ = try await runtime.send(Request(text: "hello"), in: thread.id)
            XCTFail("Expected the cross-thread provider context to fail.")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "invalid_backend_turn_event")
        }
    }

    func testAutomaticMemoryExtractionRejectsCrossThreadAssistantMessage() async throws {
        let backend = AdversarialTurnBackend(behavior: .mismatchedAssistantThread)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Reject extraction crossover",
            memoryContext: testMemoryContext
        )

        do {
            _ = try await runtime.captureMemories(
                from: .text("Remember this preference."),
                for: thread.id
            )
            XCTFail("Expected the cross-thread extraction message to fail.")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "invalid_backend_turn_event")
        }
    }

    func testAutomaticMemoryExtractionTreatsCompletionAsTerminal() async throws {
        let backend = AdversarialTurnBackend(behavior: .extractionCompletionThenFailure)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Terminal extraction completion",
            memoryContext: testMemoryContext
        )

        let capture = try await runtime.captureMemories(
            from: .text("There may be nothing to remember."),
            for: thread.id
        )

        XCTAssertTrue(capture.records.isEmpty)
    }

    func testSecondTurnStartIsRejected() async throws {
        let backend = AdversarialTurnBackend(behavior: .secondTurnStart)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(title: "Reject second start")

        do {
            _ = try await runtime.send(Request(text: "hello"), in: thread.id)
            XCTFail("Expected the second turn start to fail.")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error.code, "invalid_turn_start")
        }
    }

    func testMemoryAttributionHistoryHasBoundedPageAndScanWork() async throws {
        let stateStore = AttributionHistorySpyStore(behavior: .endlessEmptyPages)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            stateStore: stateStore
        )

        do {
            _ = try await runtime.fetchMemoryApplicationSnapshots(id: "thread", limit: 1)
            XCTFail("Expected the attribution scan limit to fail the query.")
        } catch let error as AgentStoreError {
            XCTAssertTrue(error.localizedDescription.contains("scan limit"))
        }

        let limits = await stateStore.historyQueryLimits()
        XCTAssertEqual(limits.reduce(0, +), AgentStoreLimits.maximumMemoryAttributionScanCount)
        XCTAssertTrue(limits.allSatisfy { $0 <= 8 })
    }

    func testMemoryAttributionHistoryRejectsRepeatedCursor() async throws {
        let stateStore = AttributionHistorySpyStore(behavior: .repeatedCursor)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            stateStore: stateStore
        )

        do {
            _ = try await runtime.fetchMemoryApplicationSnapshots(id: "thread", limit: 1)
            XCTFail("Expected the repeated history cursor to fail the query.")
        } catch let error as AgentStoreError {
            XCTAssertTrue(error.localizedDescription.contains("repeated cursor"))
        }

        let queryCount = await stateStore.historyQueryCount()
        XCTAssertEqual(queryCount, 2)
    }

    func testMemoryAttributionHistoryRejectsCrossThreadSnapshot() async throws {
        let stateStore = AttributionHistorySpyStore(behavior: .crossThreadSnapshot)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            stateStore: stateStore
        )

        do {
            _ = try await runtime.fetchMemoryApplicationSnapshots(id: "thread", limit: 1)
            XCTFail("Expected the cross-thread snapshot to fail the query.")
        } catch let error as AgentStoreError {
            XCTAssertTrue(error.localizedDescription.contains("cross-thread event"))
        }
    }

    func testMemoryAttributionHistoryBoundsAggregatePayload() async throws {
        let stateStore = AttributionHistorySpyStore(behavior: .largeSnapshots)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            stateStore: stateStore
        )

        do {
            _ = try await runtime.fetchMemoryApplicationSnapshots(id: "thread", limit: 100)
            XCTFail("Expected the aggregate attribution payload limit to fail the query.")
        } catch let error as AgentStoreError {
            XCTAssertTrue(error.localizedDescription.contains("materialized payloads"))
        }
    }

    func testMemoryAttributionHistoryPreservesCancellationAfterStoreReturns() async throws {
        let stateStore = AttributionHistorySpyStore(behavior: .suspendedPage)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            stateStore: stateStore
        )
        let fetchTask = Task {
            try await runtime.fetchMemoryApplicationSnapshots(id: "thread", limit: 1)
        }

        await stateStore.waitUntilHistoryQueryStarts()
        fetchTask.cancel()
        await stateStore.releaseHistoryQuery()

        do {
            _ = try await fetchTask.value
            XCTFail("Expected memory attribution history cancellation to propagate.")
        } catch is CancellationError {
            // Expected.
        }
        let queryCount = await stateStore.historyQueryCount()
        XCTAssertEqual(queryCount, 1)
    }

    func testAgentStoreErrorLocalizedDescriptionPreservesValidationReason() {
        let error = AgentStoreError.invalidInput("memory snapshot field is invalid")

        XCTAssertTrue(error.localizedDescription.contains("memory snapshot field is invalid"))
    }

    func testSendWithSummaryCorrelatesDecodedOutputWithDurableMemory() async throws {
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Typed correlation",
            memoryContext: testMemoryContext
        )
        let result = try await runtime.sendWithSummary(
            Request(text: "confirmed learning").correlated(with: "typed-123"),
            in: thread.id,
            response: ShippingReplyDraft.self
        )

        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertEqual(applications.first?.turnID, result.summary.turnID)
        XCTAssertEqual(applications.first?.clientRequestID, "typed-123")
        XCTAssertEqual(result.clientRequestID, "typed-123")
        XCTAssertEqual(result.memoryApplicationSnapshot, applications.first)
    }

    func testEphemeralResultReturnsAppliedMemoryWithoutPersistingOrRequerying() async throws {
        let store = ControlledMemoryStore(behavior: .matchingResult)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: DefaultMemoryPromptRenderer(),
            memoryStore: store
        )
        let thread = try await runtime.createThread(
            title: "Ephemeral attribution",
            memoryContext: testMemoryContext
        )
        let result = try await runtime.sendWithSummary(
            Request(
                text: "confirmed learning",
                executionMode: .ephemeral
            ).correlated(with: "ephemeral-123"),
            in: thread.id
        )

        let snapshot = try XCTUnwrap(result.memoryApplicationSnapshot)
        let durable = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        let queryInvocationCount = await store.queryInvocationCount()

        XCTAssertEqual(result.clientRequestID, "ephemeral-123")
        XCTAssertEqual(snapshot.clientRequestID, "ephemeral-123")
        XCTAssertEqual(snapshot.threadID, thread.id)
        XCTAssertEqual(snapshot.turnID, result.summary.turnID)
        XCTAssertEqual(snapshot.includedRecordIDs, ["matching-memory"])
        XCTAssertEqual(snapshot.result.matches.map(\.record.id), ["matching-memory"])
        XCTAssertEqual(queryInvocationCount, 1)
        XCTAssertTrue(durable.isEmpty)
    }

    func testSuccessfulResultDistinguishesMemoryOmissionReasons() async throws {
        let unavailableStore = ControlledMemoryStore(behavior: .failure)
        let unavailableRuntime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            memoryStore: unavailableStore
        )
        let unavailableThread = try await unavailableRuntime.createThread(
            title: "Unavailable memory",
            memoryContext: testMemoryContext
        )
        let unavailable = try await unavailableRuntime.sendWithSummary(
            Request(text: "confirmed learning"),
            in: unavailableThread.id
        )
        XCTAssertEqual(unavailable.memoryApplication.omissionReason, .unavailable)

        let noMatchesStore = ControlledMemoryStore(behavior: .emptyResult)
        let noMatchesRuntime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: DefaultMemoryPromptRenderer(),
            memoryStore: noMatchesStore
        )
        let noMatchesThread = try await noMatchesRuntime.createThread(
            title: "No matching memory",
            memoryContext: testMemoryContext
        )
        let noMatches = try await noMatchesRuntime.sendWithSummary(
            Request(text: "confirmed learning"),
            in: noMatchesThread.id
        )
        XCTAssertEqual(noMatches.memoryApplication.omissionReason, .noMatches)

        let noContextRuntime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer()
        )
        let noContextThread = try await noContextRuntime.createThread(
            title: "No memory selection context"
        )
        let noContext = try await noContextRuntime.sendWithSummary(
            Request(text: "confirmed learning"),
            in: noContextThread.id
        )
        XCTAssertEqual(noContext.memoryApplication.omissionReason, .noSelectionContext)
    }

    func testSuccessfulResultReportsWhenMemoryIsNotConfigured() async throws {
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: InMemoryRuntimeStateStore()
        ))
        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())
        let thread = try await runtime.createThread(title: "Memory not configured")

        let result = try await runtime.sendWithSummary(
            Request(text: "confirmed learning"),
            in: thread.id
        )

        XCTAssertEqual(result.memoryApplication.omissionReason, .notConfigured)
    }

    func testRendererCanApplyInstructionsWithoutSelectedRecords() async throws {
        let store = ControlledMemoryStore(behavior: .emptyResult)
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            memoryStore: store
        )
        let thread = try await runtime.createThread(
            title: "Renderer-owned memory instructions",
            memoryContext: testMemoryContext
        )

        let result = try await runtime.sendWithSummary(
            Request(text: "confirmed learning"),
            in: thread.id
        )

        XCTAssertEqual(result.memoryApplicationSnapshot?.renderedInstructions, "MEMORY")
        XCTAssertEqual(result.memoryApplicationSnapshot?.result.matches, [])
    }

    func testResultDefaultsPreserveExistingManualInitialization() {
        let summary = AgentTurnSummary(
            threadID: "thread",
            turnID: "turn"
        )
        let result = AgentTurnResult(value: "value", summary: summary)

        XCTAssertNil(result.clientRequestID)
        XCTAssertNil(result.memoryApplicationSnapshot)
        XCTAssertEqual(result.memoryApplication.omissionReason, .notReported)
    }

    func testExistingSendDoesNotRequireNewSummaryEvent() async throws {
        let runtime = try await makeMemoryInstructionRuntime(
            backend: MemoryMissingSummaryBackend(),
            renderer: MarkerMemoryRenderer()
        )
        let legacyThread = try await runtime.createThread(title: "Legacy send")

        let response = try await runtime.send(
            Request(text: "Use the existing behavior"),
            in: legacyThread.id
        )
        XCTAssertEqual(response, "Completed without a summary")

        let summaryThread = try await runtime.createThread(title: "Summary send")
        do {
            _ = try await runtime.sendWithSummary(
                Request(text: "Require a summary"),
                in: summaryThread.id
            )
            XCTFail("Expected sendWithSummary to require a completion summary.")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "turn_summary_missing")
        }
    }

    func testDurableMemoryApplicationSurvivesRuntimeReload() async throws {
        let stateStore = InMemoryRuntimeStateStore()
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            stateStore: stateStore
        )
        let thread = try await runtime.createThread(
            title: "Durable application",
            memoryContext: testMemoryContext
        )
        _ = try await runtime.send(
            Request(text: "confirmed learning").correlated(with: "reload-123"),
            in: thread.id
        )
        _ = try await runtime.send(
            Request(text: "confirmed learning again").correlated(with: "reload-456"),
            in: thread.id
        )

        let restored = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            stateStore: stateStore
        )
        let applications = try await restored.fetchMemoryApplicationSnapshots(id: thread.id)
        let newest = try await restored.fetchMemoryApplicationSnapshots(id: thread.id, limit: 1)

        XCTAssertEqual(applications.map(\.clientRequestID), ["reload-456", "reload-123"])
        XCTAssertEqual(newest.first?.clientRequestID, "reload-456")
    }

    func testSQLitePersistsDurableMemoryApplicationAcrossStoreReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime.sqlite")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            stateStore: try SQLiteRuntimeStateStore(url: url)
        )
        let thread = try await runtime.createThread(
            title: "SQLite durable application",
            memoryContext: testMemoryContext
        )
        _ = try await runtime.send(
            Request(text: "confirmed learning").correlated(with: "sqlite-123"),
            in: thread.id
        )
        _ = try await runtime.send(
            Request(text: "confirmed learning again").correlated(with: "sqlite-456"),
            in: thread.id
        )

        let restored = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            stateStore: try SQLiteRuntimeStateStore(url: url)
        )
        let applications = try await restored.fetchMemoryApplicationSnapshots(id: thread.id)
        let newest = try await restored.fetchMemoryApplicationSnapshots(id: thread.id, limit: 1)

        XCTAssertEqual(applications.map(\.clientRequestID), ["sqlite-456", "sqlite-123"])
        XCTAssertEqual(newest.first?.clientRequestID, "sqlite-456")
    }

    func testFileStorePersistsDurableMemoryApplicationAcrossReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime.json")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            stateStore: FileRuntimeStateStore(url: url)
        )
        let thread = try await runtime.createThread(
            title: "File durable application",
            memoryContext: testMemoryContext
        )
        _ = try await runtime.send(
            Request(text: "confirmed learning").correlated(with: "file-123"),
            in: thread.id
        )
        _ = try await runtime.send(
            Request(text: "confirmed learning again").correlated(with: "file-456"),
            in: thread.id
        )

        let restored = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            stateStore: FileRuntimeStateStore(url: url)
        )
        let applications = try await restored.fetchMemoryApplicationSnapshots(id: thread.id)
        let newest = try await restored.fetchMemoryApplicationSnapshots(id: thread.id, limit: 1)

        XCTAssertEqual(applications.map(\.clientRequestID), ["file-456", "file-123"])
        XCTAssertEqual(newest.first?.clientRequestID, "file-456")
    }

    func testRealmPersistsDurableMemoryApplicationAcrossStoreReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("runtime.realm")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            stateStore: try RealmRuntimeStateStore(url: url)
        )
        let thread = try await runtime.createThread(
            title: "Realm durable application",
            memoryContext: testMemoryContext
        )
        _ = try await runtime.send(
            Request(text: "confirmed learning").correlated(with: "realm-123"),
            in: thread.id
        )
        _ = try await runtime.send(
            Request(text: "confirmed learning again").correlated(with: "realm-456"),
            in: thread.id
        )

        let restored = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            stateStore: try RealmRuntimeStateStore(url: url)
        )
        let applications = try await restored.fetchMemoryApplicationSnapshots(id: thread.id)
        let newest = try await restored.fetchMemoryApplicationSnapshots(id: thread.id, limit: 1)

        XCTAssertEqual(applications.map(\.clientRequestID), ["realm-456", "realm-123"])
        XCTAssertEqual(newest.first?.clientRequestID, "realm-456")
    }

    func testLegacyRendererDoesNotOverclaimRecordAttribution() async throws {
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer()
        )
        let thread = try await runtime.createThread(
            title: "Conservative metadata",
            memoryContext: testMemoryContext
        )

        _ = try await runtime.send(Request(text: "confirmed learning"), in: thread.id)

        let applications = try await runtime.fetchMemoryApplicationSnapshots(id: thread.id)
        XCTAssertEqual(applications.first?.includedRecordIDs, [])
    }

    func testPersistedMemoryAttributionRejectsUnselectedRecordIDs() throws {
        let record = testMemoryRecords[0]
        let query = MemoryQuery(
            namespace: record.namespace,
            scopes: [record.scope],
            limit: 1
        )
        let result = MemoryQueryResult(
            matches: [
                MemoryQueryMatch(
                    record: record,
                    explanation: MemoryMatchExplanation(
                        rankingProfile: query.ranking,
                        executionMethod: .inMemory,
                        matchedTokenCount: 0,
                        queryTokenCount: 0,
                        recencyScore: 1,
                        importanceScore: record.importance
                    )
                ),
            ],
            truncated: false
        )
        let application = MemoryApplicationSnapshot(
            threadID: "thread-1",
            turnID: "turn-1",
            promptRendererIdentifier: "test-renderer",
            compiledInstructionsSHA256: String(repeating: "0", count: 64),
            query: query,
            result: result,
            renderedInstructions: "MEMORY",
            includedRecordIDs: ["not-selected"],
            placement: .beforeSkills
        )
        let item = AgentHistoryItem.systemEvent(
            AgentSystemEventRecord(
                type: .turnCompleted,
                threadID: "thread-1",
                turnID: "turn-1",
                turnSummary: AgentTurnSummary(
                    threadID: "thread-1",
                    turnID: "turn-1"
                ),
                memoryApplication: application
            )
        )

        XCTAssertThrowsError(
            try AgentStoredPayloadValidator.validateHistoryItem(
                item,
                expectedThreadID: "thread-1"
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("included memory record IDs"),
                "Unexpected validation error: \(error)"
            )
        }
    }

    func testPersistedMemoryAttributionRemainsValidAfterSelectedRecordExpires() throws {
        let record = MemoryRecord(
            id: "historical-memory",
            namespace: "test-agent",
            scope: "confirmed-learning",
            category: "learning",
            summary: "This was valid when the turn ran.",
            importance: 0.8,
            createdAt: Date(timeIntervalSinceNow: -3_600),
            expiresAt: Date(timeIntervalSinceNow: -60)
        )
        let query = MemoryQuery(
            namespace: record.namespace,
            scopes: [record.scope],
            recencyWindow: 120,
            limit: 1
        )
        let result = MemoryQueryResult(
            matches: [
                MemoryQueryMatch(
                    record: record,
                    explanation: MemoryMatchExplanation(
                        rankingProfile: query.ranking,
                        executionMethod: .inMemory,
                        matchedTokenCount: 0,
                        queryTokenCount: 0,
                        recencyScore: 0.5,
                        importanceScore: record.importance
                    )
                )
            ],
            truncated: false
        )
        let application = MemoryApplicationSnapshot(
            threadID: "thread-1",
            turnID: "turn-1",
            promptRendererIdentifier: "test-renderer",
            compiledInstructionsSHA256: String(repeating: "0", count: 64),
            query: query,
            result: result,
            renderedInstructions: "MEMORY",
            includedRecordIDs: [record.id],
            placement: .beforeSkills
        )
        let item = AgentHistoryItem.systemEvent(
            AgentSystemEventRecord(
                type: .turnCompleted,
                threadID: "thread-1",
                turnID: "turn-1",
                turnSummary: AgentTurnSummary(
                    threadID: "thread-1",
                    turnID: "turn-1"
                ),
                memoryApplication: application
            )
        )

        XCTAssertThrowsError(
            try AgentStoredPayloadValidator.validateMemoryQueryResult(
                query: query,
                result: result,
                validatesCurrentEligibility: true
            )
        )
        XCTAssertNoThrow(
            try AgentStoredPayloadValidator.validateHistoryItem(
                item,
                expectedThreadID: "thread-1"
            )
        )
    }

    func testPersistedMemoryAttributionRequiresMatchingTurnSummary() throws {
        let query = MemoryQuery(namespace: "test-agent", limit: 0)
        let application = MemoryApplicationSnapshot(
            threadID: "thread-1",
            turnID: "turn-1",
            promptRendererIdentifier: "test-renderer",
            compiledInstructionsSHA256: String(repeating: "0", count: 64),
            query: query,
            result: MemoryQueryResult(matches: [], truncated: false),
            renderedInstructions: "MEMORY",
            includedRecordIDs: [],
            placement: .beforeSkills
        )
        let missingSummary = AgentHistoryItem.systemEvent(
            AgentSystemEventRecord(
                type: .turnCompleted,
                threadID: "thread-1",
                turnID: "turn-1",
                memoryApplication: application
            )
        )
        let matchingSummary = AgentHistoryItem.systemEvent(
            AgentSystemEventRecord(
                type: .turnCompleted,
                threadID: "thread-1",
                turnID: "turn-1",
                turnSummary: AgentTurnSummary(
                    threadID: "thread-1",
                    turnID: "turn-1"
                ),
                memoryApplication: application
            )
        )

        XCTAssertThrowsError(
            try AgentStoredPayloadValidator.validateHistoryItem(
                missingSummary,
                expectedThreadID: "thread-1"
            )
        )
        XCTAssertNoThrow(
            try AgentStoredPayloadValidator.validateHistoryItem(
                matchingSummary,
                expectedThreadID: "thread-1"
            )
        )
    }

    func testApplicationObserverCannotBlockTurnCompletion() async throws {
        let observer = BlockingMemoryApplicationObserver()
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            observer: observer
        )
        let thread = try await runtime.createThread(
            title: "Non-blocking observer",
            memoryContext: testMemoryContext
        )
        let completed = expectation(description: "Send completed")
        let sendTask = Task {
            let value = try await runtime.send(
                Request(text: "confirmed learning"),
                in: thread.id
            )
            completed.fulfill()
            return value
        }

        await observer.waitUntilHandling()
        await fulfillment(of: [completed], timeout: 1)
        await observer.release()
        _ = try await sendTask.value
    }

    func testRuntimeRejectedStructuredCompletionDoesNotReportMemoryAsApplied() async throws {
        let observer = RecordingMemoryObserver()
        let runtime = try await makeMemoryInstructionRuntime(
            backend: OptionalStructuredMissingBackend(),
            renderer: MarkerMemoryRenderer(),
            observer: observer
        )
        let thread = try await runtime.createThread(
            title: "Rejected structured application",
            memoryContext: testMemoryContext
        )
        let stream = try await runtime.stream(
            Request(text: "confirmed learning"),
            in: thread.id,
            response: ShippingReplyDraft.self,
            options: .init(required: true)
        )

        do {
            try await drainStructuredStream(stream)
            XCTFail("Expected the required structured output to be missing.")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "structured_output_missing")
        }

        let applications = await observer.applications()
        XCTAssertTrue(applications.isEmpty)
    }

    func testEmptyRenderedMemoryAddsNoSectionOrApplicationSnapshot() async throws {
        let observer = RecordingMemoryObserver()
        let backend = InMemoryAgentBackend(baseInstructions: "BASE")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: EmptyMemoryRenderer(),
            observer: observer,
            placement: .beforeSkills
        )
        let thread = try await runtime.createThread(
            title: "Empty memory",
            memoryContext: testMemoryContext
        )
        let request = Request(text: "confirmed learning")

        let preview = try await runtime.resolvedInstructionsPreviewDetails(
            for: thread.id,
            request: request
        )
        XCTAssertEqual(preview.instructions, "BASE")
        XCTAssertNil(preview.memory)

        let result = try await runtime.sendWithSummary(request, in: thread.id)
        let receivedInstructions = await backend.receivedInstructions()
        let applications = await observer.applications()
        XCTAssertEqual(receivedInstructions.last, "BASE")
        XCTAssertTrue(applications.isEmpty)
        XCTAssertEqual(result.memoryApplication.omissionReason, .rendererOmittedAll)
    }

    func testDisabledMemoryAddsNoSectionOrApplicationSnapshot() async throws {
        let observer = RecordingMemoryObserver()
        let backend = InMemoryAgentBackend(baseInstructions: "BASE")
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer(),
            observer: observer,
            placement: .beforeSkills
        )
        let thread = try await runtime.createThread(
            title: "Disabled memory",
            memoryContext: testMemoryContext
        )
        let request = Request(
            text: "confirmed learning",
            memorySelection: MemorySelection(mode: .disable)
        )

        let preview = try await runtime.resolvedInstructionsPreviewDetails(
            for: thread.id,
            request: request
        )
        XCTAssertEqual(preview.instructions, "BASE")
        XCTAssertNil(preview.memory)

        let result = try await runtime.sendWithSummary(request, in: thread.id)
        let applications = await observer.applications()
        XCTAssertTrue(applications.isEmpty)
        XCTAssertEqual(result.memoryApplication.omissionReason, .disabled)
    }

    func testTurnStartupFailureDoesNotReportMemoryAsApplied() async throws {
        let observer = RecordingMemoryObserver()
        let runtime = try await makeMemoryInstructionRuntime(
            backend: MemoryStartupFailureBackend(),
            renderer: MarkerMemoryRenderer(),
            observer: observer
        )
        let thread = try await runtime.createThread(
            title: "Failed application",
            memoryContext: testMemoryContext
        )

        do {
            _ = try await runtime.send(
                Request(text: "confirmed learning"),
                in: thread.id
            )
            XCTFail("Expected turn startup to fail.")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "test_startup_failure")
        }

        let applications = await observer.applications()
        XCTAssertTrue(applications.isEmpty)
    }

    func testTurnFailureAfterStartDoesNotReportMemoryAsApplied() async throws {
        let observer = RecordingMemoryObserver()
        let runtime = try await makeMemoryInstructionRuntime(
            backend: MemoryStartedTurnFailureBackend(),
            renderer: MarkerMemoryRenderer(),
            observer: observer
        )
        let thread = try await runtime.createThread(
            title: "Failed started application",
            memoryContext: testMemoryContext
        )

        do {
            _ = try await runtime.send(
                Request(text: "confirmed learning"),
                in: thread.id
            )
            XCTFail("Expected the started turn to fail.")
        } catch {
            XCTAssertEqual((error as? AgentRuntimeError)?.code, "test_stream_failure")
        }

        let applications = await observer.applications()
        XCTAssertTrue(applications.isEmpty)
    }

    func testAutomaticCompactionReceivesSamePlacedInstructionsAsTurn() async throws {
        let backend = MemoryCompactionRecordingBackend()
        let observer = RecordingMemoryObserver()
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer(),
            observer: observer,
            placement: .beforeSkills,
            contextCompaction: .init(
                isEnabled: true,
                mode: .automatic,
                strategy: .remoteOnly,
                trigger: .init(estimatedTokenThreshold: 1)
            )
        )
        let thread = try await runtime.createThread(
            title: "Compaction placement",
            skillIDs: ["thread_skill"],
            memoryContext: testMemoryContext
        )

        _ = try await runtime.send(
            Request(text: "confirmed learning"),
            in: thread.id
        )
        _ = try await runtime.send(
            Request(
                text: String(repeating: "confirmed learning ", count: 20)
                    + "SECOND_PENDING_SENTINEL"
            ),
            in: thread.id
        )

        let compactInstructions = await backend.compactionInstructions()
        let turnInstructions = await backend.turnInstructions()
        let compactedHistories = await backend.compactionHistories()
        let turnHistories = await backend.turnHistories()
        let applications = await observer.applications(waitingFor: 2)
        XCTAssertEqual(compactInstructions, ["BASE\n\nMEMORY\n\nTHREAD SKILL"])
        XCTAssertEqual(turnInstructions, [
            "BASE\n\nMEMORY\n\nTHREAD SKILL",
            "BASE\n\nMEMORY\n\nTHREAD SKILL",
        ])
        XCTAssertFalse(compactedHistories.flatMap { $0 }.contains {
            $0.text.contains("SECOND_PENDING_SENTINEL")
        })
        XCTAssertFalse(turnHistories.flatMap { $0 }.contains {
            $0.text.contains("SECOND_PENDING_SENTINEL")
        })
        XCTAssertEqual(applications.count, 2)
        let compactedApplications = try await runtime
            .fetchMemoryCompactionApplicationSnapshots(id: thread.id)
        XCTAssertEqual(compactedApplications.count, 1)
        XCTAssertEqual(compactedApplications.first?.reason, .automaticPreTurn)
    }

    func testManualCompactionResolvesThreadSkillsForMemoryPlacement() async throws {
        let backend = MemoryCompactionRecordingBackend()
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer(),
            placement: .beforeSkills,
            contextCompaction: .init(
                isEnabled: true,
                mode: .manual,
                strategy: .remoteOnly
            )
        )
        let thread = try await runtime.createThread(
            title: "Manual compaction placement",
            skillIDs: ["thread_skill"],
            memoryContext: testMemoryContext
        )
        try await runtime.replaceSkill(
            AgentSkill(
                id: "thread_skill",
                name: "Thread",
                instructions: "THREAD SKILL",
                executionPolicy: AgentSkillExecutionPolicy(maxToolCalls: 2)
            )
        )

        _ = try await runtime.compactThreadContext(id: thread.id)

        let compactInstructions = await backend.compactionInstructions()
        XCTAssertEqual(compactInstructions, ["BASE\n\nMEMORY\n\nTHREAD SKILL"])
        XCTAssertFalse(try XCTUnwrap(compactInstructions.first).contains("Execution Policy"))
        let applications = try await runtime
            .fetchMemoryCompactionApplicationSnapshots(id: thread.id)
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(applications.first?.reason, .manual)
    }

    func testMemoryCompactionAttributionReturnsNewestGenerationFirst() async throws {
        let runtime = try await makeMemoryInstructionRuntime(
            backend: MemoryCompactionRecordingBackend(),
            renderer: MarkerMemoryRenderer(),
            contextCompaction: .init(
                isEnabled: true,
                mode: .manual,
                strategy: .remoteOnly
            )
        )
        let thread = try await runtime.createThread(
            title: "Ordered compaction attribution",
            memoryContext: testMemoryContext
        )

        _ = try await runtime.compactThreadContext(id: thread.id)
        _ = try await runtime.compactThreadContext(id: thread.id)

        let applications = try await runtime
            .fetchMemoryCompactionApplicationSnapshots(id: thread.id)
        let newest = try await runtime
            .fetchMemoryCompactionApplicationSnapshots(id: thread.id, limit: 1)
        XCTAssertEqual(applications.map(\.generation), [2, 1])
        XCTAssertEqual(newest.first?.generation, 2)
    }

    func testLocalCompactionDoesNotClaimMemoryWasApplied() async throws {
        let runtime = try await makeMemoryInstructionRuntime(
            backend: InMemoryAgentBackend(baseInstructions: "BASE"),
            renderer: MarkerMemoryRenderer(),
            contextCompaction: .init(
                isEnabled: true,
                mode: .manual,
                strategy: .localOnly
            )
        )
        let thread = try await runtime.createThread(
            title: "Local compaction attribution",
            memoryContext: testMemoryContext
        )

        _ = try await runtime.compactThreadContext(id: thread.id)

        let applications = try await runtime
            .fetchMemoryCompactionApplicationSnapshots(id: thread.id)
        XCTAssertTrue(applications.isEmpty)
    }

    func testPreferredRemoteCompactionPreservesCancellation() async throws {
        let backend = CancellationAwareCompactionBackend()
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer(),
            contextCompaction: .init(
                isEnabled: true,
                mode: .manual,
                strategy: .preferRemoteThenLocal
            )
        )
        let thread = try await runtime.createThread(
            title: "Cancelled compaction",
            memoryContext: testMemoryContext
        )
        let compactionTask = Task {
            try await runtime.compactThreadContext(id: thread.id)
        }

        await backend.waitUntilCompactionStarts()
        compactionTask.cancel()
        do {
            _ = try await compactionTask.value
            XCTFail("Expected compaction cancellation to propagate.")
        } catch is CancellationError {
            // Expected.
        }

        let contextState = try await runtime.fetchThreadContextState(id: thread.id)
        let applications = try await runtime
            .fetchMemoryCompactionApplicationSnapshots(id: thread.id)
        XCTAssertNil(contextState)
        XCTAssertTrue(applications.isEmpty)
    }

    func testCompactionChecksCancellationAfterNonCooperativeBackendReturns() async throws {
        let backend = NonCooperativeCompactionBackend()
        let runtime = try await makeMemoryInstructionRuntime(
            backend: backend,
            renderer: MarkerMemoryRenderer(),
            contextCompaction: .init(
                isEnabled: true,
                mode: .manual,
                strategy: .remoteOnly
            )
        )
        let thread = try await runtime.createThread(
            title: "Non-cooperative cancelled compaction",
            memoryContext: testMemoryContext
        )
        let compactionTask = Task {
            try await runtime.compactThreadContext(id: thread.id)
        }

        await backend.waitUntilCompactionStarts()
        compactionTask.cancel()
        await backend.release()
        do {
            _ = try await compactionTask.value
            XCTFail("Expected cancellation after backend completion to propagate.")
        } catch is CancellationError {
            // Expected.
        }

        let contextState = try await runtime.fetchThreadContextState(id: thread.id)
        let applications = try await runtime
            .fetchMemoryCompactionApplicationSnapshots(id: thread.id)
        XCTAssertNil(contextState)
        XCTAssertTrue(applications.isEmpty)
    }

    private var testMemoryContext: AgentMemoryContext {
        AgentMemoryContext(
            namespace: "test-agent",
            scopes: ["confirmed-learning"]
        )
    }

    private var testMemoryRecords: [MemoryRecord] {
        [
            MemoryRecord(
                id: "memory-1",
                namespace: "test-agent",
                scope: "confirmed-learning",
                category: "learning",
                summary: "First confirmed learning.",
                importance: 0.9
            ),
            MemoryRecord(
                id: "memory-2",
                namespace: "test-agent",
                scope: "confirmed-learning",
                category: "learning",
                summary: "Second confirmed learning.",
                importance: 0.8
            ),
        ]
    }

    private func makeMemoryInstructionRuntime(
        backend: any AgentBackend,
        renderer: any MemoryPromptRendering,
        observer: (any MemoryObserving)? = nil,
        placement: MemoryInstructionPlacement? = nil,
        records: [MemoryRecord]? = nil,
        memoryStore: (any MemoryStoring)? = nil,
        readBudget: MemoryReadBudget = .runtimeDefault,
        stateStore: any RuntimeStateStoring = InMemoryRuntimeStateStore(),
        contextCompaction: AgentContextCompactionConfiguration = .init()
    ) async throws -> AgentRuntime {
        let store: any MemoryStoring
        if let memoryStore {
            store = memoryStore
        } else {
            store = InMemoryMemoryStore(initialRecords: records ?? [testMemoryRecords[0]])
        }
        let memory: AgentMemoryConfiguration
        if let placement {
            memory = AgentMemoryConfiguration(
                store: store,
                defaultReadBudget: readBudget,
                promptRenderer: renderer,
                observer: observer,
                instructionPlacement: placement
            )
        } else {
            memory = AgentMemoryConfiguration(
                store: store,
                defaultReadBudget: readBudget,
                promptRenderer: renderer,
                observer: observer
            )
        }
        let runtime = try AgentRuntime(configuration: .init(
            authProvider: DemoChatGPTAuthProvider(),
            secureStore: KeychainSessionSecureStore(
                service: "CodexKitTests.ChatGPTSession",
                account: UUID().uuidString
            ),
            backend: backend,
            approvalPresenter: AutoApprovalPresenter(),
            stateStore: stateStore,
            memory: memory,
            skills: [
                AgentSkill(id: "thread_skill", name: "Thread", instructions: "THREAD SKILL"),
                AgentSkill(id: "turn_skill", name: "Turn", instructions: "TURN SKILL"),
            ],
            contextCompaction: contextCompaction
        ))
        _ = try await runtime.restore()
        _ = try await runtime.useSession(demoSession())
        return runtime
    }
}

private struct MarkerMemoryRenderer: MemoryPromptRendering {
    func render(result _: MemoryQueryResult, budget _: MemoryReadBudget) -> String {
        "MEMORY"
    }
}

private struct SelectiveMemoryRenderer: MemoryPromptRendering {
    func render(result _: MemoryQueryResult, budget _: MemoryReadBudget) -> String {
        "MEMORY"
    }

    func renderWithMetadata(
        result _: MemoryQueryResult,
        budget _: MemoryReadBudget
    ) -> RenderedMemoryPrompt {
        RenderedMemoryPrompt(
            instructions: "MEMORY",
            includedRecordIDs: ["memory-2", "unknown-memory", "memory-2"]
        )
    }
}

private struct EmptyMemoryRenderer: MemoryPromptRendering {
    func render(result _: MemoryQueryResult, budget _: MemoryReadBudget) -> String {
        " \n "
    }
}

private struct OversizedMemoryRenderer: MemoryPromptRendering {
    func render(result _: MemoryQueryResult, budget _: MemoryReadBudget) -> String {
        String(
            repeating: "x",
            count: AgentStoreLimits.maximumMessageTextByteCount + 1
        )
    }
}

private struct FixedMemoryRenderer: MemoryPromptRendering {
    let instructions: String

    func render(result _: MemoryQueryResult, budget _: MemoryReadBudget) -> String {
        instructions
    }
}

private final class RenderInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func recordInvocation() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func invocationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private struct RecordingMemoryRenderer: MemoryPromptRendering {
    let recorder: RenderInvocationRecorder

    func render(result _: MemoryQueryResult, budget _: MemoryReadBudget) -> String {
        recorder.recordInvocation()
        return "MEMORY"
    }
}

private struct OversizedMetadataMemoryRenderer: MemoryPromptRendering {
    func render(result _: MemoryQueryResult, budget _: MemoryReadBudget) -> String {
        "MEMORY"
    }

    func renderWithMetadata(
        result _: MemoryQueryResult,
        budget _: MemoryReadBudget
    ) -> RenderedMemoryPrompt {
        RenderedMemoryPrompt(
            instructions: "MEMORY",
            includedRecordIDs: Array(
                repeating: "memory-1",
                count: MemoryStoreLimits.maximumQueryResultCount + 1
            )
        )
    }
}

private actor ControlledMemoryStore: MemoryStoring {
    enum Behavior: Sendable {
        case waitForCancellation
        case matchingResult
        case failure
        case oversizedResult
        case outOfScopeResult
        case cursorWithoutMatch
        case emptyResult
    }

    private let behavior: Behavior
    private let backing = InMemoryMemoryStore()
    private var didStartQuery = false
    private var queryCount = 0
    private var queryStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func put(_ record: MemoryRecord) async throws {
        try await backing.put(record)
    }

    func putMany(_ records: [MemoryRecord]) async throws {
        try await backing.putMany(records)
    }

    func upsert(_ record: MemoryRecord, dedupeKey: String) async throws {
        try await backing.upsert(record, dedupeKey: dedupeKey)
    }

    func query(_ query: MemoryQuery) async throws -> MemoryQueryResult {
        queryCount += 1
        didStartQuery = true
        queryStartWaiters.forEach { $0.resume() }
        queryStartWaiters.removeAll()

        switch behavior {
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(60))
            return MemoryQueryResult(matches: [], truncated: false)

        case .matchingResult:
            let record = MemoryRecord(
                id: "matching-memory",
                namespace: query.namespace,
                scope: query.scopes.first ?? "confirmed-learning",
                category: "learning",
                summary: "Confirmed learning from prior use.",
                importance: 0.9
            )
            let queryTokens = Set(MemoryQueryEngine.uniqueTokens(query.text))
            return MemoryQueryResult(
                matches: [
                    MemoryQueryEngine.makeMatch(
                        record: record,
                        query: query,
                        now: Date(),
                        matchedTokenCount: MemoryQueryEngine.matchedTokenCount(
                            for: record,
                            queryTokens: queryTokens
                        ),
                        queryTokenCount: queryTokens.count
                    )
                ],
                truncated: false
            )

        case .failure:
            throw AgentStoreError.queryNotSupported("Simulated unavailable memory store")

        case .oversizedResult:
            let matches = (0 ... query.limit).map { index in
                MemoryQueryMatch(
                    record: MemoryRecord(
                        id: "invalid-result-\(index)",
                        namespace: query.namespace,
                        scope: query.scopes.first ?? MemoryScope(rawValue: "confirmed-learning"),
                        category: "learning",
                        summary: "Invalid unbounded result \(index)",
                        importance: 0.5
                    ),
                    explanation: MemoryMatchExplanation(
                        rankingProfile: query.ranking,
                        executionMethod: .inMemory,
                        matchedTokenCount: 0,
                        queryTokenCount: 0,
                        recencyScore: 0.5,
                        importanceScore: 0.5
                    )
                )
            }
            return MemoryQueryResult(matches: matches, truncated: false)

        case .outOfScopeResult:
            let record = MemoryRecord(
                id: "out-of-scope-result",
                namespace: query.namespace,
                scope: "different-scope",
                category: "learning",
                summary: "Confirmed learning outside the selected scope.",
                importance: 0.5
            )
            let queryTokens = Set(MemoryQueryEngine.uniqueTokens(query.text))
            return MemoryQueryResult(
                matches: [
                    MemoryQueryEngine.makeMatch(
                        record: record,
                        query: query,
                        now: Date(),
                        matchedTokenCount: MemoryQueryEngine.matchedTokenCount(
                            for: record,
                            queryTokens: queryTokens
                        ),
                        queryTokenCount: queryTokens.count
                    )
                ],
                truncated: false
            )

        case .cursorWithoutMatch:
            return MemoryQueryResult(
                matches: [],
                truncated: true,
                nextCursor: MemoryQueryCursor(
                    namespace: query.namespace,
                    rankingProfile: query.ranking,
                    importance: 0.5,
                    effectiveDate: Date(),
                    recordOrder: 0,
                    recordID: "missing-final-record"
                )
            )

        case .emptyResult:
            return MemoryQueryResult(matches: [], truncated: false)
        }
    }

    func record(id: String, namespace: String) async throws -> MemoryRecord? {
        try await backing.record(id: id, namespace: namespace)
    }

    func list(_ query: MemoryRecordListQuery) async throws -> [MemoryRecord] {
        try await backing.list(query)
    }

    func diagnostics(namespace: String) async throws -> MemoryStoreDiagnostics {
        try await backing.diagnostics(namespace: namespace)
    }

    func compact(_ request: MemoryCompactionRequest) async throws {
        try await backing.compact(request)
    }

    func archive(ids: [String], namespace: String) async throws {
        try await backing.archive(ids: ids, namespace: namespace)
    }

    func delete(ids: [String], namespace: String) async throws {
        try await backing.delete(ids: ids, namespace: namespace)
    }

    func pruneExpired(now: Date, namespace: String) async throws -> Int {
        try await backing.pruneExpired(now: now, namespace: namespace)
    }

    func waitUntilQueryStarts() async {
        guard !didStartQuery else { return }
        await withCheckedContinuation { continuation in
            queryStartWaiters.append(continuation)
        }
    }

    func queryInvocationCount() -> Int {
        queryCount
    }
}

private struct MemorySearchFixture: Codable, Sendable {
    let surface: String
}

private actor BlockingMemoryApplicationObserver: MemoryObserving {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func handle(event _: MemoryObservationEvent) async {}

    func handle(application _: MemoryApplicationSnapshot) async {
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilHandling() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor TurnStartSignal {
    private var didStart = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        didStart = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private enum AdversarialTurnBehavior: Sendable {
    case completionThenFailure(structured: Bool)
    case extractionCompletionThenFailure
    case mismatchedAssistantThread
    case mismatchedDeltaTurn
    case mismatchedToolTurn
    case mismatchedProviderThread
    case secondTurnStart
}

private struct ExpectedPostCompletionFailure: Error, Sendable {}

private actor AdversarialTurnBackend: AgentBackend {
    private let behavior: AdversarialTurnBehavior

    init(behavior: AdversarialTurnBehavior) {
        self.behavior = behavior
    }

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message _: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        let behavior = behavior
        let turn = AgentTurn(id: "active-turn", threadID: thread.id)
        return AgentTurnStream(
            events: AsyncThrowingStream { continuation in
                continuation.yield(.turnStarted(turn))
                switch behavior {
                case let .completionThenFailure(structured):
                    if structured {
                        continuation.yield(
                            .structuredOutputCommitted(
                                .object([
                                    "reply": .string("Structured echo"),
                                    "priority": .string("normal"),
                                ])
                            )
                        )
                    }
                    continuation.yield(
                        .assistantMessageCompleted(
                            AgentMessage(
                                threadID: thread.id,
                                role: .assistant,
                                text: structured
                                    ? #"{"reply":"Structured echo","priority":"normal"}"#
                                    : "Completed"
                            )
                        )
                    )
                    let summary = AgentTurnSummary(
                        threadID: thread.id,
                        turnID: turn.id,
                        usage: AgentUsage(inputTokens: 1, outputTokens: 1)
                    )
                    continuation.yield(.turnCompleted(summary))
                    continuation.yield(.turnCompleted(summary))
                    continuation.finish(throwing: ExpectedPostCompletionFailure())

                case .extractionCompletionThenFailure:
                    continuation.yield(
                        .structuredOutputCommitted(
                            .object(["memories": .array([])])
                        )
                    )
                    continuation.yield(
                        .assistantMessageCompleted(
                            AgentMessage(
                                threadID: thread.id,
                                role: .assistant,
                                text: #"{"memories":[]}"#
                            )
                        )
                    )
                    let summary = AgentTurnSummary(
                        threadID: thread.id,
                        turnID: turn.id,
                        usage: AgentUsage(inputTokens: 1, outputTokens: 1)
                    )
                    continuation.yield(.turnCompleted(summary))
                    continuation.yield(.turnCompleted(summary))
                    continuation.finish(throwing: ExpectedPostCompletionFailure())

                case .mismatchedAssistantThread:
                    continuation.yield(
                        .assistantMessageCompleted(
                            AgentMessage(
                                threadID: "different-thread",
                                role: .assistant,
                                text: "Wrong thread"
                            )
                        )
                    )
                    continuation.finish()

                case .mismatchedDeltaTurn:
                    continuation.yield(
                        .assistantMessageDelta(
                            threadID: thread.id,
                            turnID: "different-turn",
                            delta: "Wrong turn"
                        )
                    )
                    continuation.finish()

                case .mismatchedToolTurn:
                    continuation.yield(
                        .toolCallRequested(
                            ToolInvocation(
                                id: "wrong-turn-tool",
                                threadID: thread.id,
                                turnID: "different-turn",
                                toolName: "not_registered",
                                arguments: .object([:])
                            )
                        )
                    )
                    continuation.finish()

                case .mismatchedProviderThread:
                    continuation.yield(
                        .providerContextUpdated(
                            threadID: "different-thread",
                            context: AgentProviderContext(
                                providerID: "test",
                                payload: .object([:])
                            )
                        )
                    )
                    continuation.finish()

                case .secondTurnStart:
                    continuation.yield(
                        .turnStarted(
                            AgentTurn(id: "second-turn", threadID: thread.id)
                        )
                    )
                    continuation.finish()
                }
            }
        )
    }
}

private actor AttributionHistorySpyStore: RuntimeStateStoring, RuntimeStateInspecting {
    enum Behavior: Sendable {
        case endlessEmptyPages
        case repeatedCursor
        case crossThreadSnapshot
        case largeSnapshots
        case suspendedPage
    }

    private let behavior: Behavior
    private let backing = InMemoryRuntimeStateStore()
    private var queryLimits: [Int] = []
    private var pageNumber = 0
    private var didStartSuspendedPage = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func loadState() async throws -> StoredRuntimeState {
        try await backing.loadState()
    }

    func saveState(_ state: StoredRuntimeState) async throws {
        try await backing.saveState(state)
    }

    func prepare() async throws -> AgentStoreMetadata {
        try await backing.prepare()
    }

    func readMetadata() async throws -> AgentStoreMetadata {
        try await backing.readMetadata()
    }

    func apply(_ operations: [AgentStoreWriteOperation]) async throws {
        try await backing.apply(operations)
    }

    func fetchThreadSummary(id: String) async throws -> AgentThreadSummary {
        try await backing.fetchThreadSummary(id: id)
    }

    func fetchThreadHistory(
        id: String,
        query: AgentHistoryQuery
    ) async throws -> AgentThreadHistoryPage {
        queryLimits.append(query.limit)
        pageNumber += 1
        let nextCursor: AgentHistoryCursor?
        let items: [AgentHistoryItem]
        switch behavior {
        case .endlessEmptyPages:
            nextCursor = AgentHistoryCursor(rawValue: "page-\(pageNumber)")
            items = []
        case .repeatedCursor:
            nextCursor = AgentHistoryCursor(rawValue: "repeated")
            items = []
        case .crossThreadSnapshot:
            nextCursor = nil
            items = [largeMemoryApplicationEvent(threadID: "different-thread")]
        case .largeSnapshots:
            nextCursor = AgentHistoryCursor(rawValue: "page-\(pageNumber)")
            items = Array(repeating: largeMemoryApplicationEvent(threadID: id), count: query.limit)
        case .suspendedPage:
            didStartSuspendedPage = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            nextCursor = nil
            items = []
        }
        return AgentThreadHistoryPage(
            threadID: id,
            items: items,
            nextCursor: nextCursor,
            previousCursor: nil,
            hasMoreBefore: true,
            hasMoreAfter: false
        )
    }

    func fetchLatestStructuredOutputMetadata(
        id: String
    ) async throws -> AgentStructuredOutputMetadata? {
        try await backing.fetchLatestStructuredOutputMetadata(id: id)
    }

    func fetchThreadContextState(id: String) async throws -> AgentThreadContextState? {
        try await backing.fetchThreadContextState(id: id)
    }

    func historyQueryLimits() -> [Int] {
        queryLimits
    }

    func historyQueryCount() -> Int {
        queryLimits.count
    }

    func waitUntilHistoryQueryStarts() async {
        guard !didStartSuspendedPage else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseHistoryQuery() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func largeMemoryApplicationEvent(threadID: String) -> AgentHistoryItem {
        let snapshot = MemoryApplicationSnapshot(
            threadID: threadID,
            turnID: "turn",
            promptRendererIdentifier: "test",
            compiledInstructionsSHA256: String(repeating: "a", count: 64),
            query: MemoryQuery(namespace: "test"),
            result: MemoryQueryResult(matches: [], truncated: false),
            renderedInstructions: String(repeating: "x", count: 1 * 1_024 * 1_024),
            includedRecordIDs: [],
            placement: .afterSkills
        )
        return .systemEvent(
            AgentSystemEventRecord(
                type: .turnCompleted,
                threadID: threadID,
                turnID: "turn",
                turnSummary: AgentTurnSummary(
                    threadID: threadID,
                    turnID: "turn"
                ),
                memoryApplication: snapshot
            )
        )
    }
}

private actor MismatchedCompletionBackend: AgentBackend {
    private let emitsStructuredOutput: Bool
    private let mismatchesStartedThread: Bool
    private let startedTurnID: String

    init(
        emitsStructuredOutput: Bool,
        mismatchesStartedThread: Bool = false,
        startedTurnID: String = "started-turn"
    ) {
        self.emitsStructuredOutput = emitsStructuredOutput
        self.mismatchesStartedThread = mismatchesStartedThread
        self.startedTurnID = startedTurnID
    }

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message _: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        let turn = AgentTurn(
            id: startedTurnID,
            threadID: mismatchesStartedThread ? "different-thread" : thread.id
        )
        let payload: JSONValue = .object([
            "reply": .string("Structured echo"),
            "priority": .string("normal"),
        ])
        return AgentTurnStream(
            events: AsyncThrowingStream { continuation in
                continuation.yield(.turnStarted(turn))
                if emitsStructuredOutput {
                    continuation.yield(.structuredOutputCommitted(payload))
                }
                continuation.yield(
                    .assistantMessageCompleted(
                        AgentMessage(
                            threadID: thread.id,
                            role: .assistant,
                            text: emitsStructuredOutput
                                ? #"{"reply":"Structured echo","priority":"normal"}"#
                                : "Completed"
                        )
                    )
                )
                continuation.yield(
                    .turnCompleted(
                        AgentTurnSummary(
                            threadID: thread.id,
                            turnID: "different-completed-turn",
                            usage: AgentUsage(inputTokens: 1, outputTokens: 1)
                        )
                    )
                )
                continuation.finish()
            }
        )
    }
}

private actor NonCooperativeCompletionBackend: AgentBackend {
    private let emitsStructuredOutput: Bool
    private var didStartTurn = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(emitsStructuredOutput: Bool) {
        self.emitsStructuredOutput = emitsStructuredOutput
    }

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message _: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        let events = AsyncThrowingStream<AgentBackendEvent, Error> { continuation in
            Task {
                await self.produceEvents(thread: thread, continuation: continuation)
            }
        }
        return AgentTurnStream(events: events)
    }

    private func produceEvents(
        thread: AgentThread,
        continuation: AsyncThrowingStream<AgentBackendEvent, Error>.Continuation
    ) async {
        let turn = AgentTurn(id: "non-cooperative-turn", threadID: thread.id)
        continuation.yield(.turnStarted(turn))
        didStartTurn = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        if emitsStructuredOutput {
            continuation.yield(
                .structuredOutputCommitted(
                    .object([
                        "reply": .string("Structured echo"),
                        "priority": .string("normal"),
                    ])
                )
            )
        }
        continuation.yield(
            .assistantMessageCompleted(
                AgentMessage(
                    threadID: thread.id,
                    role: .assistant,
                    text: emitsStructuredOutput
                        ? #"{"reply":"Structured echo","priority":"normal"}"#
                        : "Completed"
                )
            )
        )
        continuation.yield(
            .turnCompleted(
                AgentTurnSummary(
                    threadID: thread.id,
                    turnID: turn.id,
                    usage: AgentUsage(inputTokens: 1, outputTokens: 1)
                )
            )
        )
        continuation.finish()
    }

    func waitUntilTurnStarts() async {
        guard !didStartTurn else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor MemoryCompactionRecordingBackend: AgentBackend, AgentBackendContextCompacting {
    let baseInstructions: String? = "BASE"
    private var recordedCompactionInstructions: [String] = []
    private var recordedTurnInstructions: [String] = []
    private var recordedCompactionHistories: [[AgentMessage]] = []
    private var recordedTurnHistories: [[AgentMessage]] = []

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history: [AgentMessage],
        message: Request,
        instructions: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        recordedTurnInstructions.append(instructions)
        recordedTurnHistories.append(history)
        return MockAgentTurnSession(
            thread: thread,
            message: message,
            selectedTool: nil,
            structuredResponseText: nil,
            streamedStructuredOutput: nil
        ).stream
    }

    func compactContext(
        thread _: AgentThread,
        effectiveHistory: [AgentMessage],
        instructions: String,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentCompactionResult {
        recordedCompactionInstructions.append(instructions)
        recordedCompactionHistories.append(effectiveHistory)
        return AgentCompactionResult(
            effectiveMessages: effectiveHistory,
            summaryPreview: "Compacted"
        )
    }

    func compactionInstructions() -> [String] {
        recordedCompactionInstructions
    }

    func turnInstructions() -> [String] {
        recordedTurnInstructions
    }

    func compactionHistories() -> [[AgentMessage]] {
        recordedCompactionHistories
    }

    func turnHistories() -> [[AgentMessage]] {
        recordedTurnHistories
    }
}

private actor CancellationAwareCompactionBackend: AgentBackend, AgentBackendContextCompacting {
    private var didStartCompaction = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        MockAgentTurnSession(
            thread: thread,
            message: message,
            selectedTool: nil,
            structuredResponseText: nil,
            streamedStructuredOutput: nil
        ).stream
    }

    func compactContext(
        thread _: AgentThread,
        effectiveHistory _: [AgentMessage],
        instructions _: String,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentCompactionResult {
        didStartCompaction = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await Task.sleep(for: .seconds(60))
        return AgentCompactionResult(effectiveMessages: [])
    }

    func waitUntilCompactionStarts() async {
        guard !didStartCompaction else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor NonCooperativeCompactionBackend: AgentBackend, AgentBackendContextCompacting {
    private var didStartCompaction = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        MockAgentTurnSession(
            thread: thread,
            message: message,
            selectedTool: nil,
            structuredResponseText: nil,
            streamedStructuredOutput: nil
        ).stream
    }

    func compactContext(
        thread _: AgentThread,
        effectiveHistory: [AgentMessage],
        instructions _: String,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentCompactionResult {
        didStartCompaction = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return AgentCompactionResult(effectiveMessages: effectiveHistory)
    }

    func waitUntilCompactionStarts() async {
        guard !didStartCompaction else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor MemoryStartupFailureBackend: AgentBackend {
    let baseInstructions: String? = "BASE"

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread _: AgentThread,
        history _: [AgentMessage],
        message _: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        throw AgentRuntimeError(
            code: "test_startup_failure",
            message: "The test backend rejected the turn before it started."
        )
    }
}

private actor MemoryStartedTurnFailureBackend: AgentBackend {
    let baseInstructions: String? = "BASE"

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message _: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)
        let events = AsyncThrowingStream<AgentBackendEvent, Error> { continuation in
            continuation.yield(.turnStarted(turn))
            continuation.finish(
                throwing: AgentRuntimeError(
                    code: "test_stream_failure",
                    message: "The test backend failed after starting the turn."
                )
            )
        }
        return AgentTurnStream(events: events)
    }
}

private actor MemoryMissingSummaryBackend: AgentBackend {
    let baseInstructions: String? = "BASE"

    func createThread(session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: UUID().uuidString)
    }

    func resumeThread(id: String, session _: ChatGPTSession) async throws -> AgentThread {
        AgentThread(id: id)
    }

    func beginTurn(
        thread: AgentThread,
        history _: [AgentMessage],
        message _: Request,
        instructions _: String,
        responseFormat _: AgentStructuredOutputFormat?,
        streamedStructuredOutput _: AgentStreamedStructuredOutputRequest?,
        tools _: [ToolDefinition],
        session _: ChatGPTSession
    ) async throws -> AgentTurnStream {
        let turn = AgentTurn(id: UUID().uuidString, threadID: thread.id)
        let events = AsyncThrowingStream<AgentBackendEvent, Error> { continuation in
            continuation.yield(.turnStarted(turn))
            continuation.yield(
                .assistantMessageCompleted(
                    AgentMessage(
                        threadID: thread.id,
                        role: .assistant,
                        text: "Completed without a summary"
                    )
                )
            )
            continuation.finish()
        }
        return AgentTurnStream(events: events)
    }
}
