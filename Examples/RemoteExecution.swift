import CodexKit

// The host supplies packets from its existing provider-request preparation path.
// Middleware authentication/device headers are configured on the client.
func submitRemoteExamples(
    client: CodexRemoteExecutionClient,
    preparedResponse: CodexRemotePreparedResponse,
    preparedImage: CodexRemotePreparedImage,
    session: ChatGPTSession
) async throws -> (response: CodexRemoteJob, image: CodexRemoteJob) {
    let authentication = CodexRemoteAuthentication(session: session)

    // Choose the preference when creating this request's remoteExecution.
    let remoteExecution = CodexRemoteExecution(
        preparedRequest: .response(preparedResponse),
        completionPush: .regular
    )
    let response = try await client.execute(remoteExecution: remoteExecution, authentication: authentication)

    // Omission defaults to silent; completionPush: .silent is equivalent.
    let imageExecution = CodexRemoteExecution(preparedRequest: .image(preparedImage))
    let image = try await client.execute(remoteExecution: imageExecution, authentication: authentication)

    // Keep these execution values if submission needs to be retried explicitly.
    // Automatic HTTP retries already preserve the full envelope and preference.
    return (response, image)
}
