import CallRecorderCore
import Foundation
import Testing
@testable import CallRecorderApp

@Suite("Brief runtime")
struct SummarizerTests {
    @Test("a Mac without the runtime, and one without the model, are told apart")
    func readinessNamesWhatIsMissing() {
        let file = URL(filePath: "/tmp/model.gguf")

        #expect(Summarizer.readiness(runtime: nil, model: file) == .runtimeUnavailable)
        #expect(Summarizer.readiness(runtime: file, model: nil) == .modelUnavailable)
        #expect(Summarizer.readiness(runtime: file, model: file) == nil)
        // The sentence a person reads has to name the command that fixes it.
        #expect(SummarizerError.runtimeUnavailable.errorDescription?.contains("brew install")
            == true)
    }

    @Test("the request is written in the shape the server reads")
    func theRequestMatchesTheServersApi() throws {
        let request = SummarizerRequest(
            messages: [
                .init(role: "system", content: "You write a brief."),
                .init(role: "user", content: "Transcript:"),
            ],
            temperature: 0.3,
            maxTokens: 512
        )

        let data = try JSONEncoder().encode(request)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(json["temperature"] as? Double == 0.3)
        #expect(json["max_tokens"] as? Int == 512)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[1]["content"] == "Transcript:")
    }

    @Test("the answer is read out of the server's reply, and an empty one is refused")
    func theReplyIsReadWithoutTheEnvelope() throws {
        // A raw literal: the text is JSON, and JSON spells its own newlines.
        let reply = #"""
            {"choices":[{"message":{"role":"assistant","content":"## About\nThe launch."}}]}
            """#

        let decoded = try JSONDecoder().decode(
            SummarizerResponse.self,
            from: Data(reply.utf8)
        )
        #expect(decoded.text == "## About\nThe launch.")

        let empty = try JSONDecoder().decode(
            SummarizerResponse.self,
            from: Data(#"{"choices":[{"message":{"content":null}}]}"#.utf8)
        )
        #expect(empty.text == nil)
    }

    @Test("the server is given a port that was free when it was chosen")
    func theServerGetsAFreePort() throws {
        let port = try #require(SummarizerServer.freePort())

        // Above the registered range, which is where the kernel hands ports out.
        #expect(port > 1_024)
        #expect(port <= 65_535)
    }
}
