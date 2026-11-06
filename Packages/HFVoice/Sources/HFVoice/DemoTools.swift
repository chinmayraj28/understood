import Foundation
import HFCore

/// A tool for trying the voice layer on its own (`hf-voice text`, `hf-voice talk`, the
/// live test). It changes nothing on the Mac; it only reports that it was called.
public enum DemoTools {
    public static let volumeToolName = "demo_set_volume"

    public static func make(onCall: @escaping @Sendable (_ name: String, _ parameters: JSONObject) -> Void = { _, _ in }) -> [ToolSpec] {
        [
            ToolSpec(
                name: volumeToolName,
                description: "Set the Mac's output volume to a percentage. Use for any request to change the volume, such as 'volume to 30'. This is a demo: it reports the new level without changing anything.",
                parameters: [
                    "type": "object",
                    "properties": ["percent": ["type": "integer", "description": "0 to 100"]],
                    "required": ["percent"],
                ],
                tier: .quick,
                timeoutSeconds: 10
            ) { parameters in
                onCall(volumeToolName, parameters)
                guard let percent = parameters["percent"]?.intValue, (0...100).contains(percent) else {
                    return ToolResult.failure("The volume must be between 0 and 100.")
                }
                return ToolResult.ok(["volume": .number(Double(percent))])
            }
        ]
    }
}
