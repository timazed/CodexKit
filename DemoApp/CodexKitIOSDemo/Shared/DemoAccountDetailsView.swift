import CodexKit
import SwiftUI

/// Displays resolved account metadata only; credentials never enter this view.
struct DemoAccountDetailsView: View {
    let account: ChatGPTAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ChatGPT account")
                .font(.subheadline.weight(.semibold))
            detail("Plan", value: planLabel)
            detail("Name", value: displayValue(account.name))
            detail("Email", value: displayValue(account.email, placeholder: "unknown@chatgpt.local"))
            detail("Account ID", value: displayValue(account.id, placeholder: "unknown-account"))
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ title: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } label: {
            Text(title).foregroundStyle(.secondary)
        }
    }

    private func displayValue(_ value: String?, placeholder: String? = nil) -> String {
        guard let value else { return "Not available" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != placeholder else { return "Not available" }
        return trimmed
    }

    private var planLabel: String {
        switch account.plan {
        case .free: "Free"
        case .go: "Go"
        case .plus: "Plus"
        case .pro: "Pro"
        case .proLite: "Pro Lite"
        case .team: "Team"
        case .business: "Business"
        case .selfServeBusinessProLite: "Self-serve Business Pro Lite"
        case .selfServeBusinessUsageBased: "Self-serve Business Usage Based"
        case .enterprise: "Enterprise"
        case .ent26: "Enterprise (Ent26)"
        case .enterpriseCbpAutomation: "Enterprise CBP Automation"
        case .enterpriseCbpUsageBased: "Enterprise CBP Usage Based"
        case .edu: "Education"
        case .eduPlus: "Education Plus"
        case .eduPro: "Education Pro"
        case .unknown: "Unknown"
        }
    }
}

#Preview("Account details") {
    DemoAccountDetailsView(account: .init(
        id: "workspace-example",
        email: "example@example.test",
        plan: .plus,
        name: "Example User"
    ))
    .padding()
    .frame(width: 280)
}
