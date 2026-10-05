import Foundation
import Testing
@testable import Orbit

@Suite("JSONValue")
struct JSONValueTests {
    @Test func roundTripsAndSortsKeys() throws {
        let value = try JSONValue.parse(#"{"b":1,"a":[true,null,"x",2.5],"c":{"z":"/path"}}"#)
        #expect(value.jsonString() == #"{"a":[true,null,"x",2.5],"b":1,"c":{"z":"/path"}}"#)
        #expect(value["b"]?.intValue == 1)
        #expect(value["a"]?[0]?.boolValue == true)
    }

    @Test func wholeNumbersEncodeWithoutFraction() {
        #expect(JSONValue.number(20).jsonString() == "20")
        #expect(JSONValue.number(-3).jsonString() == "-3")
        #expect(JSONValue.number(0.5).jsonString() == "0.5")
    }

    @Test func distinguishesBoolFromNumberInFoundationObjects() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"flag":true,"n":1}"#.utf8))
        let value = try #require(JSONValue(any: object))
        #expect(value["flag"] == .bool(true))
        #expect(value["n"] == .number(1))
    }

    @Test func intValueRejectsNumbersOutsideInt() {
        #expect(JSONValue.number(9_223_372_036_854_775_808).intValue == nil) // 2^63 must not trap
        #expect(JSONValue.number(-9_223_372_036_854_775_808).intValue == Int.min)
        #expect(JSONValue.number(1.5).intValue == nil)
        #expect(JSONValue.number(42).intValue == 42)
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: JSONValue.ParseError.self) { try JSONValue.parse("{not json") }
    }
}

@Suite("JSONSchema")
struct JSONSchemaTests {
    let schema: JSONSchema = .object(properties: [
        "query": .string(description: "q"),
        "kind": .string(enumValues: ["pdf", "image"]),
        "limit": .integer(minimum: 1, maximum: 50),
        "modified_after": .string(format: .dateTime),
        "unread_only": .boolean(),
        "to": .array(items: .string()),
    ], required: ["query"])

    @Test func acceptsValidInput() {
        let result = schema.validate(["query": "invoice", "kind": "pdf", "limit": 10])
        #expect(result.isValid)
        #expect(result.value["limit"] == .number(10))
    }

    @Test func normalizesWhatModelsPlausiblyMeant() {
        let result = schema.validate([
            "Query": "invoice", "kind": "PDF", "limit": "5", "modifiedAfter": "2026-03-01",
            "unread_only": "true", "to": "lisa@example.com", "ignored": .null,
        ])
        #expect(result.errors == ["Unknown parameter 'ignored'. Expected parameters: kind, limit, modified_after, query, to, unread_only."])
        #expect(result.value["query"] == "invoice")
        #expect(result.value["kind"] == "pdf")
        #expect(result.value["limit"] == .number(5))
        #expect(result.value["modified_after"] == "2026-03-01")
        #expect(result.value["unread_only"] == .bool(true))
        #expect(result.value["to"] == ["lisa@example.com"])
    }

    @Test func reportsProblemsForTheModel() {
        let result = schema.validate(["kind": "doc", "limit": 500, "modified_after": "last week"])
        #expect(result.errors.contains("Missing required parameter 'query'."))
        #expect(result.errors.contains("'kind' must be one of: pdf, image. Got 'doc'."))
        #expect(result.errors.contains("'limit' must be at most 50."))
        #expect(result.errors.contains { $0.hasPrefix("'modified_after' must be an ISO 8601 date") })
    }

    @Test func parsesDoubleEncodedArguments() {
        let result = schema.validate(.string(#"{"query":"x"}"#))
        #expect(result.isValid)
        #expect(result.value["query"] == "x")
    }

    @Test func serializesToolSchema() {
        let json = JSONSchema.object(properties: ["a": .integer(minimum: 1)], required: ["a"]).jsonValue
        #expect(json.jsonString() == #"{"additionalProperties":false,"properties":{"a":{"minimum":1,"type":"integer"}},"required":["a"],"type":"object"}"#)
    }
}

@Suite("FlexibleDate")
struct FlexibleDateTests {
    let berlin = TimeZone(identifier: "Europe/Berlin")!

    @Test func parsesDateOnlyInLocalZone() throws {
        let parsed = try #require(FlexibleDate.parse("2026-03-01", timeZone: berlin))
        #expect(parsed.isDateOnly)
        #expect(FlexibleDate.iso8601(parsed.date, timeZone: berlin) == "2026-03-01T00:00:00+01:00")
    }

    @Test(arguments: [
        ("2026-07-10T14:30", "2026-07-10T14:30:00+02:00"),
        ("2026-07-10 14:30:15", "2026-07-10T14:30:15+02:00"),
        ("2026-07-10T14:30:15Z", "2026-07-10T16:30:15+02:00"),
        ("2026-07-10T14:30:15+00:00", "2026-07-10T16:30:15+02:00"),
        ("2026-07-10T14:30:15-0500", "2026-07-10T21:30:15+02:00"),
        ("2026-07-10T14:30:15.250+02:00", "2026-07-10T14:30:15+02:00"),
    ])
    func parsesDateTimes(input: String, expected: String) throws {
        let parsed = try #require(FlexibleDate.parse(input, timeZone: berlin))
        #expect(!parsed.isDateOnly)
        #expect(FlexibleDate.iso8601(parsed.date, timeZone: berlin) == expected)
    }

    @Test(arguments: ["yesterday", "2026-13-01", "2026-02-30", "26-01-01", "2026-01-01T25:00", ""])
    func rejectsInvalidDates(input: String) {
        #expect(FlexibleDate.parse(input, timeZone: berlin) == nil)
    }

    @Test func endOfDay() throws {
        let parsed = try #require(FlexibleDate.parse("2026-03-01", timeZone: berlin))
        let end = FlexibleDate.endOfDay(parsed.date, timeZone: berlin)
        #expect(FlexibleDate.iso8601(end, timeZone: berlin) == "2026-03-01T23:59:59+01:00")
    }
}

@Suite("ToolRegistry")
struct ToolRegistryTests {
    struct EchoTool: Tool {
        var name = "search_files"
        var description = "Echo"
        var inputSchema: JSONSchema = .empty
        var riskLevel: ToolRiskLevel = .read
        var category: ToolCategory = .files
        var requiredPermissions: [PermissionKind] = [.fullDiskAccess]
        func run(arguments: ToolArguments) async throws -> ToolResult { ToolResult(text: "ok") }
    }

    struct DeniedPermissions: PermissionStatusProviding {
        func status(of permission: PermissionKind) -> PermissionStatus { .denied }
    }

    @Test func toleratesNearMissNames() {
        let registry = ToolRegistry(tools: [EchoTool()])
        #expect(registry.tool(named: "search_files") != nil)
        #expect(registry.tool(named: "Search_Files") != nil)
        #expect(registry.tool(named: "searchFiles") != nil)
        #expect(registry.tool(named: "search_mail") == nil)
    }

    @Test func reportsAvailability() {
        let registry = ToolRegistry(tools: [EchoTool()])
        let denied = registry.availability(disabledToolNames: [], permissions: DeniedPermissions())
        #expect(denied.first?.unavailableReason == .permissionMissing(.fullDiskAccess))
        let disabled = registry.availability(disabledToolNames: ["search_files"], permissions: AllPermissionsGranted())
        #expect(disabled.first?.unavailableReason == .disabledByUser)
        let fine = registry.availability(disabledToolNames: [], permissions: AllPermissionsGranted())
        #expect(fine.first?.isAvailable == true)
    }
}
