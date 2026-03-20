import CodexKit
import CodexKitUI
import SwiftUI

@available(iOS 17.0, macOS 14.0, *)
struct DeviceCodePromptView: View {
    let prompt: ChatGPTDeviceCodePrompt

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Finish Sign-In")
                .font(.title3.weight(.semibold))

            Text("Open the verification page, sign in with ChatGPT, and enter this one-time code.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Code")
                    .font(.headline)
                Text(prompt.userCode)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.secondary.opacity(0.10))
                    )
            }

            HStack(spacing: 12) {
                Button("Open Verification Page") {
                    openURL(prompt.verificationURL)
                }
                .buttonStyle(.borderedProminent)
            }

            Text(prompt.verificationURL.absoluteString)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("Return to the app after entering the code to finish sign-in.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
