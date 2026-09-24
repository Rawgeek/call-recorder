import CallRecorderCore
import SwiftUI

/// The window that follows a call while it is being recorded.
///
/// Three bands, in the order they are wanted: what is happening, what was said, and the field for
/// asking about it. The window is a reading aid and says so at the bottom, because the file the app
/// stands behind is written after the call, from the recording, and a person reading a sentence
/// here should know which of the two they are looking at.
struct LiveTranscriptView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    /// Whether the newest line is on screen, so the view only follows the conversation while the
    /// reader is already at its end.
    ///
    /// Amanu shipped the other behaviour first: the view followed every new line, which scrolls the
    /// text somebody is reading out from under them the moment the call continues. Following is a
    /// courtesy until it is a fight.
    @State private var isAtTheEnd = true
    /// Which reading of the call is on screen: the summary the model keeps rewriting, or the words
    /// themselves. The words come first because they are useful the moment they arrive, and the
    /// first summary takes the screen once it exists -- unless the reader has already chosen, in
    /// which case nothing moves under them.
    @State private var reading: Reading = .words
    /// Whether the person has touched the switch. Set by the switch alone, never by the view.
    @State private var readerChoseReading = false

    private enum Reading: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case words = "Words"

        var id: String { rawValue }
    }

    /// The width the times are drawn in, so the words of every line start in one column.
    private static let timeColumn: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            sideNotice
            if !model.liveSummary.isEmpty {
                CRDivider()
                readingSwitch
            }
            CRDivider()
            conversation
            CRDivider()
            questions
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(backgroundWash)
        .onChange(of: model.liveSummary) { _, summary in
            guard !summary.isEmpty, !readerChoseReading else { return }
            withAnimation(.easeOut(duration: 0.15)) { reading = .summary }
        }
        // A window opened again in the middle of a call is opened to the summary when one has
        // already been written: catching up is what it was opened for, and the switch is right
        // there for reading the words instead.
        .onAppear {
            if !model.liveSummary.isEmpty { reading = .summary }
        }
    }

    /// The two readings of the same call, and how much the summary has been rewritten.
    private var readingSwitch: some View {
        HStack(spacing: CR.Space.item) {
            Picker("", selection: readingBinding) {
                ForEach(Reading.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            Spacer(minLength: CR.Space.item)
            Text(
                model.liveSummaryUpdates <= 1
                    ? "Written once so far"
                    : "Rewritten \(model.liveSummaryUpdates) times"
            )
            .font(CR.Font.caption)
            .foregroundStyle(CR.Ink.mark)
        }
        .padding(.horizontal, CR.Space.screen)
        .padding(.vertical, CR.Space.item)
    }

    private var readingBinding: Binding<Reading> {
        Binding(
            get: { reading },
            set: { chosen in
                readerChoseReading = true
                reading = chosen
            }
        )
    }

    private var backgroundWash: some View {
        if #available(macOS 26.0, *) {
            Color.clear
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    // MARK: - What is happening

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: CR.Space.inner) {
            VStack(alignment: .leading, spacing: CR.Space.tight) {
                HStack(spacing: CR.Space.inner) {
                    if isRecording {
                        CRLiveDot()
                    }
                    Text(model.liveStatus.headline)
                        .font(.system(size: 17, weight: .semibold))
                }
                if let detail = model.liveStatus.detail {
                    Text(detail)
                        .font(CR.Font.callout)
                        .foregroundStyle(
                            model.liveStatus.isProblem
                                ? AnyShapeStyle(CR.Tone.failed.ink)
                                : CR.Ink.readable
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: CR.Space.item)
            statusChip
            CRButton(title: "Hide", kind: .secondary) {
                dismissWindow(id: "live-transcript")
            }
            .help("Hide this window. The recording carries on.")
        }
        .padding(CR.Space.screen)
    }

    private var isRecording: Bool {
        model.recorderState.phase == .recording || model.recorderState.phase == .paused
    }

    /// One side of the call has produced no words, and the window says so.
    ///
    /// It sits under the header rather than inside the conversation because it is about the audio
    /// rather than about anything said: reading it changes what the person does about the call —
    /// plug in the headphones the far side is playing through, pick up the phone — while a call is
    /// still running.
    @ViewBuilder
    private var sideNotice: some View {
        if let notice = model.liveTranscript.unheardSideNotice(atSeconds: elapsedSeconds) {
            HStack(alignment: .firstTextBaseline, spacing: CR.Space.tight) {
                Image(systemName: "ear")
                    .imageScale(.small)
                Text(notice)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(CR.Font.callout)
            .foregroundStyle(CR.Tone.waiting.ink)
            .padding(.horizontal, CR.Space.screen)
            .padding(.bottom, CR.Space.item)
        }
    }

    /// How much of this call has been recorded, read the way the menu bar reads it.
    private var elapsedSeconds: TimeInterval {
        AppModel.recordedSeconds(
            banked: model.recordedSecondsBeforePause,
            currentRunStartedAt: model.recordingStartedAt,
            paused: false,
            at: Date()
        )
    }

    @ViewBuilder
    private var statusChip: some View {
        switch model.liveStatus {
        case .listening:
            CRStatusChip(tone: .ready, text: "Live")
        case .starting:
            CRStatusChip(tone: .working, text: "Starting")
        case let .behind(seconds):
            CRStatusChip(tone: .waiting, text: LiveTranscriptStatus.duration(seconds))
        case .failed:
            CRStatusChip(tone: .failed, text: "Stopped")
        case .idle, .stopped:
            CRStatusChip(tone: .muted, text: "Not live")
        }
    }

    // MARK: - What was said

    @ViewBuilder
    private var conversation: some View {
        if reading == .summary {
            summaryReading
        } else {
            wordsReading
        }
    }

    /// The call so far, as the model keeps rewriting it.
    @ViewBuilder
    private var summaryReading: some View {
        ScrollView {
            Text(model.liveSummary)
                .font(CR.Font.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CR.Space.screen)
                .padding(.vertical, CR.Space.section)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var wordsReading: some View {
        if model.liveTranscript.isEmpty {
            CREmptyState(
                icon: model.liveStatus.isProblem ? "exclamationmark.bubble" : "waveform",
                title: model.liveStatus.isProblem ? "Live text is not running" : "Nothing said yet",
                message: model.liveStatus.detail
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: CR.Space.item) {
                        ForEach(blocks) { block in
                            speakerBlock(block, proxy: proxy)
                        }
                    }
                    .padding(.horizontal, CR.Space.screen)
                    .padding(.vertical, CR.Space.section)
                }
                // Only text that grows away from the reader is followed. Scrolling up is a request
                // to read, and the view answers it by staying still.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height
                        - (geometry.contentOffset.y + geometry.containerSize.height) < 24
                } action: { _, atTheEnd in
                    isAtTheEnd = atTheEnd
                }
                .onChange(of: model.liveTranscript.entries.count) { _, _ in
                    guard isAtTheEnd, let last = blocks.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    if let last = blocks.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func speakerBlock(_ block: LiveSpeakerBlock, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: CR.Space.snug) {
            HStack(spacing: CR.Space.inner) {
                Text(block.speaker)
                    .font(CR.Font.headline)
                    .foregroundStyle(block.source == .microphone ? CR.Tone.ready.ink : CR.Tone.working.ink)
                Text(LiveTranscript.clock(block.startSeconds))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(CR.Ink.mark)
            }
            ForEach(block.entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: CR.Space.inner) {
                    Text(entry.timeLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(CR.Ink.mark)
                        .frame(width: Self.timeColumn, alignment: .leading)
                    Text(entry.text)
                        .font(CR.Font.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id(entry.id)
            }
        }
        .id(block.id)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The conversation with each side's consecutive lines gathered under one name.
    private var blocks: [LiveSpeakerBlock] {
        LiveSpeakerBlock.blocks(from: model.liveTranscript.entries)
    }

    // MARK: - Asking about it

    private var questions: some View {
        VStack(alignment: .leading, spacing: CR.Space.item) {
            if let answer = model.liveChatAnswer {
                answerCard(answer)
            } else if let failure = model.liveChatFailure, !failure.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: CR.Space.inner) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CR.Tone.waiting.ink)
                    Text(failure)
                        .font(CR.Font.caption)
                        .foregroundStyle(CR.Ink.readable)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            askField
            recommended
            footer
        }
        .padding(CR.Space.screen)
    }

    private var askField: some View {
        HStack(spacing: CR.Space.inner) {
            CRTextField(placeholder: "Ask about this call…", text: $model.liveQuestion) {
                model.askLiveQuestion()
            }
            CRButton(title: "Ask", icon: "sparkles", kind: .primary, action: model.askLiveQuestion)
                .disabled(askDisabled)
            if model.liveChatRunning {
                CRProgressRing(progress: nil)
                    .frame(width: CR.Icon.infoSlot, height: CR.Icon.infoSlot)
            }
        }
    }

    private var askDisabled: Bool {
        model.liveChatRunning
            || model.liveQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.liveStatus.acceptsQuestions
    }

    private var recommended: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: CR.Space.inner)],
            alignment: .leading,
            spacing: CR.Space.inner
        ) {
            ForEach(LiveChat.recommendedQuestions, id: \.self) { question in
                CRButton(title: question, kind: .secondary) {
                    model.askLiveQuestion(question)
                }
                .disabled(model.liveChatRunning || !model.liveStatus.acceptsQuestions)
            }
        }
    }

    private func answerCard(_ answer: LiveChatAnswer) -> some View {
        VStack(alignment: .leading, spacing: CR.Space.snug) {
            HStack(alignment: .firstTextBaseline, spacing: CR.Space.inner) {
                Text(answer.question)
                    .font(CR.Font.headline)
                Spacer(minLength: 0)
                CRIconButton(icon: "xmark", label: "Dismiss the answer", alwaysVisible: true) {
                    model.dismissLiveAnswer()
                }
            }
            Text(answer.answer)
                .font(CR.Font.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            CRButton(title: "Ask again", kind: .secondary) {
                model.askLiveQuestion(answer.question)
            }
            .disabled(model.liveChatRunning || !model.liveStatus.acceptsQuestions)
        }
        .padding(CR.Space.item)
        .frame(maxWidth: .infinity, alignment: .leading)
        .crSurface(.rounded(CR.Radius.medium), tint: CR.Tone.working.color)
    }

    /// The line that says what this text is, and what it is not.
    private var footer: some View {
        VStack(alignment: .leading, spacing: CR.Space.hairline) {
            Text(
                "A reading aid while the call runs. The transcript that is kept is written from "
                    + "the recording when the call ends."
            )
            if model.liveTranscript.droppedChunks > 0 {
                Text(
                    model.liveTranscript.droppedChunks == 1
                        ? "1 piece of audio was given up on because this Mac could not keep up, "
                            + "so some words are missing."
                        : "\(model.liveTranscript.droppedChunks) pieces of audio were given up on "
                            + "because this Mac could not keep up, so some words are missing."
                )
                .foregroundStyle(CR.Tone.waiting.ink)
            }
        }
        .font(CR.Font.caption)
        .foregroundStyle(CR.Ink.readable)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Consecutive lines from one side, gathered under one name.
struct LiveSpeakerBlock: Identifiable {
    let id: UUID
    let speaker: String
    let source: LiveAudioSource
    let startSeconds: Double
    var entries: [LiveTranscriptEntry]

    /// Gathers a conversation into the blocks the window draws.
    static func blocks(from entries: [LiveTranscriptEntry]) -> [LiveSpeakerBlock] {
        var blocks: [LiveSpeakerBlock] = []
        for entry in entries {
            if var last = blocks.last, last.speaker == entry.speaker {
                last.entries.append(entry)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(
                    LiveSpeakerBlock(
                        id: entry.id,
                        speaker: entry.speaker,
                        source: entry.source,
                        startSeconds: entry.startSeconds,
                        entries: [entry]
                    )
                )
            }
        }
        return blocks
    }
}
