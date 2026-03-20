import CodexKit
import Foundation

@MainActor
extension AgentDemoViewModel {
    func registerDemoTool() async {
        let definition = ToolDefinition(
            name: "demo_calculate_shipping_quote",
            description: "Calculate a deterministic demo shipping quote, including price and estimated delivery days.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "destination_zone": .object([
                        "type": .string("string"),
                        "description": .string("Destination zone: A, B, C, or D."),
                    ]),
                    "weight_kg": .object([
                        "type": .string("number"),
                        "description": .string("Package weight in kilograms."),
                    ]),
                    "speed": .object([
                        "type": .string("string"),
                        "description": .string("Shipping speed: standard, express, or priority."),
                    ]),
                    "signature_required": .object([
                        "type": .string("boolean"),
                        "description": .string("Whether signature on delivery is required."),
                    ]),
                ]),
            ]),
            approvalPolicy: .requiresApproval,
            approvalMessage: "Allow the demo app to calculate a shipping quote?"
        )

        do {
            try await runtime.replaceTool(definition, executor: AnyToolExecutor { invocation, _ in
                Self.logger.info(
                    "Executing tool \(invocation.toolName, privacy: .public) with arguments: \(String(describing: invocation.arguments), privacy: .public)"
                )
                let result = Self.makeShippingQuote(invocation: invocation)
                Self.logger.info(
                    "Tool \(invocation.toolName, privacy: .public) returned: \(result.primaryText ?? "<no text result>", privacy: .public)"
                )
                return result
            })
        } catch {
            lastError = error.localizedDescription
        }
    }

    nonisolated static func makeShippingQuote(invocation: ToolInvocation) -> ToolResultEnvelope {
        guard case let .object(arguments) = invocation.arguments else {
            return .failure(
                invocation: invocation,
                message: "The shipping quote tool expected object arguments."
            )
        }

        let destinationZone = arguments["destination_zone"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        let speed = arguments["speed"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "standard"
        let weightKilograms = arguments["weight_kg"]?.numberValue ?? 0
        let signatureRequired = arguments["signature_required"]?.boolValue ?? false

        let basePriceByZone: [String: Double] = [
            "A": 4.0,
            "B": 6.5,
            "C": 9.0,
            "D": 12.5,
        ]
        let speedMultipliers: [String: Double] = [
            "standard": 1.0,
            "express": 1.6,
            "priority": 2.1,
        ]
        let deliveryDaysBySpeedAndZone: [String: [String: Int]] = [
            "standard": ["A": 2, "B": 4, "C": 6, "D": 8],
            "express": ["A": 1, "B": 2, "C": 3, "D": 4],
            "priority": ["A": 1, "B": 1, "C": 2, "D": 3],
        ]

        guard let zoneBasePrice = basePriceByZone[destinationZone] else {
            return .failure(
                invocation: invocation,
                message: "Unknown destination zone. Use A, B, C, or D."
            )
        }

        guard let speedMultiplier = speedMultipliers[speed] else {
            return .failure(
                invocation: invocation,
                message: "Unknown shipping speed. Use standard, express, or priority."
            )
        }

        guard weightKilograms > 0 else {
            return .failure(
                invocation: invocation,
                message: "Weight must be greater than zero kilograms."
            )
        }

        let signatureSurcharge = signatureRequired ? 2.5 : 0
        let subtotal = (zoneBasePrice + (weightKilograms * 1.75)) * speedMultiplier
        let total = round((subtotal + signatureSurcharge) * 100) / 100
        let deliveryDays = deliveryDaysBySpeedAndZone[speed]?[destinationZone] ?? 0

        return .success(
            invocation: invocation,
            text: """
            quote[zone=\(destinationZone), weightKg=\(Self.formattedDecimal(weightKilograms)), speed=\(speed), signatureRequired=\(signatureRequired ? "yes" : "no"), totalUSD=\(Self.formattedDecimal(total)), estimatedDeliveryDays=\(deliveryDays), reference=DEMO-\(destinationZone)-\(speed.uppercased())]
            """
        )
    }

    nonisolated static func formattedDecimal(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private extension JSONValue {
    var numberValue: Double? {
        guard case let .number(value) = self else {
            return nil
        }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else {
            return nil
        }
        return value
    }
}
