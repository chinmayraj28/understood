import Foundation
import HFCore
import Testing

@testable import HFVoice

@Suite struct ToolRouterTests {
    let received = Recorder<JSONObject>()

    func router() -> ToolRouter {
        let received = self.received
        return ToolRouter(tools: [
            ToolSpec(name: "echo", description: "echo", parameters: ["type": "object"], tier: .quick) { parameters in
                received.add(parameters)
                return ToolResult.ok(["got": .object(parameters)])
            },
            ToolSpec(name: "broken", description: "fails", parameters: ["type": "object"], tier: .quick) { _ in
                ToolResult.failure("The volume must be between 0 and 100.")
            },
        ])
    }

    @Test func parametersBecomeAJSONObjectWithoutTheCallID() async {
        let json = Data(#"{"percent":30,"app":"Spotify","flags":[true,null],"nested":{"x":1.5},"tool_call_id":"abc"}"#.utf8)
        _ = await router().handle(toolName: "echo", parametersJSON: json)
        let parameters = received.all.first
        #expect(parameters?["percent"]?.intValue == 30)
        #expect(parameters?["app"]?.stringValue == "Spotify")
        #expect(parameters?["flags"] == [true, nil])
        #expect(parameters?["nested"]?["x"]?.doubleValue == 1.5)
        #expect(parameters?["tool_call_id"] == nil)
    }

    @Test func theResultIsJSONTextNotAnObject() async throws {
        let reply = await router().handle(toolName: "echo", parametersJSON: Data(#"{"percent":30}"#.utf8))
        #expect(reply.isError == false)
        #expect(reply.text == #"{"got":{"percent":30},"ok":true}"#)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(reply.text.utf8))
        #expect(decoded["ok"]?.boolValue == true)
    }

    @Test func aFailureIsMarkedAsAnError() async {
        let reply = await router().handle(toolName: "broken", parametersJSON: Data("{}".utf8))
        #expect(reply.isError)
        #expect(reply.text.contains("The volume must be between 0 and 100."))
    }

    @Test func anUnknownToolIsAFailureNotACrash() async {
        let reply = await router().handle(toolName: "missing", parametersJSON: Data())
        #expect(reply.isError)
        #expect(reply.text.contains(#""ok":false"#))
    }

    @Test func parametersThatAreNotAnObjectBecomeEmpty() async {
        _ = await router().handle(toolName: "echo", parametersJSON: Data("[1,2]".utf8))
        _ = await router().handle(toolName: "echo", parametersJSON: Data("not json".utf8))
        #expect(received.all == [[:], [:]])
    }
}
