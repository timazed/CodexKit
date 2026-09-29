import CodexKit
import SwiftUI

struct ImageGenerationDiagnosticsView: View {
    let details: AgentImageGenerationDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let limit = details.usageLimit {
                Text("Image allowance reached").font(.headline)
                if let date = limit.resetsAt {
                    Text("Resets: \(date.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Reset time unavailable")
                }
            }
            Text("Client request ID: \(details.clientRequestID)")
            if let id = details.requestID { Text("Request ID: \(id)") }
            if let id = details.imageRequestID { Text("Image request ID: \(id)") }
            if let id = details.generationID { Text("Generation ID: \(id)") }
        }.font(.caption.monospaced()).textSelection(.enabled)
    }
}
