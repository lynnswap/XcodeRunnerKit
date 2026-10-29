import ArgumentParser
import Foundation
import MCP
import XcodeRunnerHostSupport

struct SettingsMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Serve host settings over MCP on standard input/output.")

    mutating func run() async throws {
        let service = HostSettingsService()
        let server = Server(name: "xcode-runner", version: "0.0.0", capabilities: .init(tools: .init()))
        let tools = try Self.tools()
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { request in
            do {
                switch request.name {
                case "get_settings":
                    let arguments = request.arguments ?? [:]
                    guard arguments.keys.allSatisfy({ $0 == "scope" }) else { throw HostSettingsError("get_settings accepts only scope.") }
                    let scope: HostSettingsScope?
                    if let value = arguments["scope"] {
                        guard let name = value.stringValue, let parsed = HostSettingsScope(rawValue: name) else {
                            throw HostSettingsError("Unknown settings scope.")
                        }
                        scope = parsed
                    } else { scope = nil }
                    return try Self.result(await service.getSettings(scope: scope))
                case "update_settings":
                    let data = try JSONEncoder().encode(request.arguments ?? [:])
                    let update = try JSONDecoder().decode(HostSettingsUpdate.self, from: data)
                    return try Self.result(await service.update(update))
                default:
                    throw HostSettingsError("Unknown tool: \(request.name)")
                }
            } catch {
                let message = error.localizedDescription
                return .init(
                    content: [.text(text: message, annotations: nil, _meta: nil)],
                    structuredContent: .object(["error": .string(message)]), isError: true
                )
            }
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    private static func result(_ result: some Codable) throws -> CallTool.Result {
        let data = try JSONEncoder().encode(result)
        return try .init(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            structuredContent: result, isError: false
        )
    }

    private static func tools() throws -> [Tool] {
        let settingSchema = try schema(#"""
        {
          "type":"object",
          "required":["key","scope","type","defaultValue","constraints","choices","appliesAt","editable"],
          "properties":{
            "key":{"type":"string"},"scope":{"type":"string"},"type":{"type":"string"},
            "value":{},"activeValue":{},"defaultValue":{},"constraints":{"type":"object"},
            "choices":{"type":"array","items":{"type":"object","required":["value","label"],"properties":{"value":{},"label":{"type":"string"}}}},
            "appliesAt":{"type":"string"},"editable":{"type":"boolean"},
            "unavailableReason":{"type":"string"},"readError":{"type":"string"}
          }
        }
        """#)
        let errorSchema: Value = .object([
            "type": .string("object"), "required": .array([.string("error")]),
            "properties": .object(["error": .object(["type": .string("string")])])
        ])
        let settingsProperty: Value = .object(["type": .string("array"), "items": settingSchema])
        let snapshotSchema: Value = .object([
            "type": .string("object"), "required": .array([.string("settings")]),
            "properties": .object(["settings": settingsProperty])
        ])
        let updateSchema: Value = .object([
            "type": .string("object"), "required": .array([.string("scope"), .string("state"), .string("settings"), .string("errors")]),
            "properties": .object([
                "scope": .object(["type": .string("string")]), "state": .object(["enum": .array([.string("saved"), .string("savedWithErrors")])]),
                "settings": settingsProperty,
                "errors": .object(["type": .string("array"), "items": .object(["type": .string("string")])])
            ])
        ])
        return [
            Tool(
                name: "get_settings", description: "List current host settings, value types, defaults, choices, constraints, and application timing. Read failures are reported per setting. GitHub edits require the running host app.",
                inputSchema: try schema(#"""
                {"type":"object","additionalProperties":false,"properties":{"scope":{"enum":["pool","buildService","storage","githubRepositories"]}}}
                """#),
                annotations: .init(readOnlyHint: true, openWorldHint: false),
                outputSchema: .object(["type": .string("object"), "oneOf": .array([snapshotSchema, errorSchema])])
            ),
            Tool(
                name: "update_settings", description: "Update one settings group, preserving unspecified fields. Pool maximum and retention are saved together. Running jobs continue. Returns saved values, application timing, and any cleanup or repository synchronization errors. Storage applies on the next host launch. Does not restart the host.",
                inputSchema: try schema(#"""
                {
                  "type":"object",
                  "oneOf":[
                    {"type":"object","additionalProperties":false,"required":["scope"],"anyOf":[{"required":["maximumConcurrentJobs"]},{"required":["simulatorRetention"]}],"properties":{
                      "scope":{"const":"pool"},"maximumConcurrentJobs":{"type":"integer","minimum":1},
                      "simulatorRetention":{"oneOf":[
                        {"type":"object","additionalProperties":false,"required":["mode"],"properties":{"mode":{"const":"forever"}}},
                        {"type":"object","additionalProperties":false,"required":["mode","minutes"],"properties":{"mode":{"const":"idleTimeout"},"minutes":{"type":"integer","minimum":1}}}
                      ]}
                    }},
                    {"type":"object","additionalProperties":false,"required":["scope","path"],"properties":{"scope":{"const":"buildService"},"path":{"type":["string","null"],"pattern":"^/"}}},
                    {"type":"object","additionalProperties":false,"required":["scope","directory"],"properties":{"scope":{"const":"storage"},"directory":{"type":"string","pattern":"^/"}}},
                    {"type":"object","additionalProperties":false,"required":["scope","selectedRepositoryIDs"],"properties":{"scope":{"const":"githubRepositories"},"selectedRepositoryIDs":{"type":"array","uniqueItems":true,"items":{"type":"integer","minimum":1}}}}
                  ]
                }
                """#),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true),
                outputSchema: .object(["type": .string("object"), "oneOf": .array([updateSchema, errorSchema])])
            )
        ]
    }

    private static func schema(_ json: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }
}
