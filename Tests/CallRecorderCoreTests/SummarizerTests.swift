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
            maxTokens: 512,
            chatTemplateKwargs: SummarizerRequest.plainAnswer
        )

        let data = try JSONEncoder().encode(request)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(json["temperature"] as? Double == 0.3)
        #expect(json["max_tokens"] as? Int == 512)
        // Qwen3.5 reasons before it answers unless its template is told not to, and the reasoning
        // is not part of a brief.
        let kwargs = try #require(json["chat_template_kwargs"] as? [String: Bool])
        #expect(kwargs["enable_thinking"] == false)
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

    @Test("reasoning written in front of an answer is not part of the answer")
    func reasoningIsStrippedFromTheBrief() {
        let withOneBlock = "<think>\nThe call is about a launch.\n</think>\n\n## About\nThe launch."
        #expect(Summarizer.withoutReasoning(withOneBlock) == "## About\nThe launch.")
        // A model that stopped mid-thought left half a brief, and half a brief is not kept.
        #expect(Summarizer.withoutReasoning("<think>\nThe call is about") == "")
        // A template that ignores the setting writes no block, and its answer is left alone.
        #expect(Summarizer.withoutReasoning("  ## About\nThe launch.  ") == "## About\nThe launch.")
    }

    @Test("the server is given a port that was free when it was chosen")
    func theServerGetsAFreePort() throws {
        let port = try #require(SummarizerServer.freePort())

        // Above the registered range, which is where the kernel hands ports out.
        #expect(port > 1_024)
        #expect(port <= 65_535)
    }

    @Test("the model server is told how much prompt cache it may keep")
    func theServerIsGivenACacheCeiling() throws {
        let fromScratch = SummarizerServer.environment(from: ["PATH": "/usr/bin", "HOME": "/Users/x"])

        // llama.cpp's own default is eight gigabytes of RAM for a cache this app never asked for,
        // and a live window that holds one server for a whole call fills it.
        #expect(fromScratch["LLAMA_ARG_CACHE_RAM"] == "512")
        #expect(SummarizerServer.promptCacheMiB > 0)
        #expect(SummarizerServer.promptCacheMiB <= 1_024)
        // Nothing else is disturbed: the server finds its libraries on the paths it was given.
        #expect(fromScratch["PATH"] == "/usr/bin")
        #expect(fromScratch["HOME"] == "/Users/x")

        // The server that is about to be started is the one that carries it.
        let server = try SummarizerServer(
            executable: URL(filePath: "/opt/homebrew/bin/llama-server"),
            model: URL(filePath: "/tmp/model.gguf"),
            contextTokens: 8_192,
            log: nil
        )
        #expect(server.launchEnvironment["LLAMA_ARG_CACHE_RAM"] == "512")
        // The environment is the app's own, with the ceiling added rather than in place of it.
        #expect(server.launchEnvironment["PATH"] != nil)
    }

    @Test("the ceiling is asked for by variable, so a server that predates it still starts")
    func theCacheCeilingIsNotAnArgument() throws {
        let server = try SummarizerServer(
            executable: URL(filePath: "/opt/homebrew/bin/llama-server"),
            model: URL(filePath: "/tmp/model.gguf"),
            contextTokens: 8_192,
            log: nil
        )
        let arguments = server.launchArguments

        // The arguments the server is meant to be run with are still there.
        #expect(arguments.contains("--model"))
        #expect(arguments.contains("/tmp/model.gguf"))
        #expect(arguments.contains("--ctx-size"))
        #expect(arguments.contains("8192"))
        #expect(arguments.contains("--parallel"))
        #expect(arguments.contains("1"))
        #expect(arguments.contains("--no-webui"))

        // An unknown argument stops llama-server from starting at all, which would take the brief
        // and the live window with it; an unknown variable is ignored.
        #expect(!arguments.contains("--cache-ram"))
        #expect(!arguments.contains("--cache-reuse"))
        // The port the arguments carry is the one the app will knock on.
        #expect(arguments.contains("--port"))
        #expect(arguments.contains(String(server.port)))
    }
}
