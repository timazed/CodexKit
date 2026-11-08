# Build a Swift AI agent with app-defined tools

[Documentation index](index.md) · [CodexKit](../README.md)

Turn a conversational assistant into an agent that can use your app's capabilities. CodexKit sends tool definitions to the model, routes requested calls to your Swift executors, and returns results to the model. Your app owns each implementation and its authorization.

## Register a capability

Start with the [SwiftUI assistant](swiftui-assistant.md). In `ChatViewModel.start()`, register the tool after creating `runtime` and before constructing `AgentRuntimeStore`. The completed walkthrough already includes this registration; replace it rather than registering the same name twice:

```swift
try await runtime.registerTool(
    ToolDefinition(
        name: "project_status",
        description: "Read the current project's status.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ]),
        approvalPolicy: .requiresApproval,
        approvalMessage: "Share the current project status with the assistant?"
    ),
    executor: AnyToolExecutor { invocation, _ in
        // Replace this sample result with an authorized read from your app.
        .success(invocation: invocation, text: "Sample project: 3 tasks remaining.")
    }
)

```

Ask: “Use project_status to tell me how the project is going.” Tool selection is model-driven; a prompt does not guarantee a call. When requested, the sample asks for approval before returning a fixed illustrative status. Replace that result with a read from your app's data store to make the capability useful.

## Present the approval

The starter's approval controls display the request title and message, then call `approveCurrent()` or `denyCurrent()` on `ApprovalInbox`. Keep these controls enabled during generation: the runtime is waiting for the decision. Denial becomes a tool failure result; it must not execute the protected action.

For a tool that changes app state, describe the action and relevant arguments in the approval experience, validate the arguments in the executor, check the current user's permissions, and perform the actual mutation there. A model-generated request is not authorization. OS permissions such as HealthKit access remain separate from the SDK approval flow.

## Return a result and continue

Use `.success(invocation:text:)` or `.failure(invocation:message:)` to preserve the original invocation identity. The runtime records the outcome and returns it to the model so it can continue the response. Tool-result text is model-visible: include only the data required for the task.

Register tools again when constructing a new runtime; persisted conversations do not recreate Swift executor closures. Tools execute serially by default. Opt into parallel execution only for independent operations that are safe to overlap, and handle cancellation in longer-running executors.

For limits, structured failures, and parallel execution, see [runtime progress, tools, and turn control](upstream-runtime-features.md). For real app integrations, explore the [demo tools](../DemoApp/CodexKitIOSDemo/Shared/AgentDemoViewModel+Tools.swift).
