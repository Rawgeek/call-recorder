import AVFoundation
import CallRecorderCore
import SwiftUI

/// The window where an unknown voice becomes a person.
///
/// The job is a listening task, so each voice is one card that holds everything the user needs to
/// make the call: what the voice said, what it sounds like, and the two ways to finish. The old
/// layout spread the same information across a list row with four nested controls.
struct SpeakerReviewView: View {
    @Bindable var model: AppModel
    @State private var selections: [SpeakerClusterID: ParticipantID] = [:]
    /// The one player over the call's recording, shared by the picture and the samples.
    ///
    /// Pressing play on a sample moves the playhead on the timeline above it, so the words are heard
    /// where they were said; one player is what keeps the two surfaces from disagreeing about where
    /// the recording is.
    @State private var playback = CallPlayback()
    /// The sample being listened to, so the pauses inside it are skipped and it stops at its end.
    @State private var listeningPass: SpeakerTimeline.ListeningPass?
    @State private var playingClusterID: SpeakerClusterID?
    @State private var playbackError: String?
    @State private var playingSampleStart: Int?
    @State private var expandedSpeakers: Set<SpeakerClusterID> = []
    @State private var voiceCounts: [CallID: Int] = [:]
    /// The voice whose card the window has opened under the picture.
    @State private var selectedClusterID: SpeakerClusterID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            CRDivider()
            if let error = model.voiceIdentityError {
                voiceIdentityUnavailable(error)
            } else if model.voiceIdentityState != .available {
                // The list is read through the same locked store as everything else on this
                // window, so while the key is unread the list is empty and the window used to
                // draw "Nothing to review" over nine voices that were waiting. Saying which wait
                // it is in keeps that from reading as an answer.
                voiceIdentityWaiting
            } else {
                ScrollViewReader { proxy in
                    content
                        .onChange(of: selectedClusterID) { _, clusterID in
                            guard let clusterID else { return }
                            // The card for the voice is placed first among the cards; this walks the
                            // list to it, because a call with twenty voices puts it off screen.
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(clusterID, anchor: .center)
                            }
                        }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .background(backgroundWash)
        .task {
            await model.refreshSpeakerReviews()
            seedSelections()
            if model.speakerRuntimeMessage == "Speaker setup has not been checked." {
                await model.checkSpeakerRuntime()
            }
        }
        .onChange(of: model.speakerReviews) { _, _ in
            seedSelections()
            Task { await model.refreshSpeakerReviewEvidence() }
        }
        .onChange(of: playback.positionMs) { _, position in
            skipPauses(at: position)
        }
        .onAppear {
            // A render has no pointer, so the renderer names the voice the window opens with
            // selected. A click sets the same state and always wins: it arrives after the window
            // is up, and only the renderer sets the model's side of it.
            if selectedClusterID == nil {
                selectedClusterID = model.previewSelectedSpeakerClusterID
            }
        }
        .onDisappear { stopPlayback() }
        .alert("Couldn't Play Audio", isPresented: playbackErrorPresented) {
            Button("OK") { playbackError = nil }
        } message: {
            Text(playbackError ?? "The audio sample is unavailable.")
        }
        .alert("Couldn't Update Speaker", isPresented: speakerFailurePresented) {
            Button("Copy Details") {
                model.copyErrorDetails()
                model.dismissSpeakerReviewFailure()
            }
            Button("OK", role: .cancel) { model.dismissSpeakerReviewFailure() }
        } message: {
            Text(model.speakerReviewFailure ?? "The speaker could not be updated.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: CR.Space.inner) {
            HStack(alignment: .firstTextBaseline, spacing: CR.Space.inner) {
                VStack(alignment: .leading, spacing: CR.Space.tight) {
                    Text("Who is speaking?")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Listen, choose a name, then confirm. The transcript updates and the voice is learned.")
                        .font(CR.Font.callout)
                        .foregroundStyle(CR.Ink.readable)
                }
                Spacer(minLength: CR.Space.item)
                if totalPendingVoices > 0 {
                    CRStatusChip(tone: .waiting, text: "\(totalPendingVoices) to name")
                }
            }

            HStack(spacing: CR.Space.snug) {
                CRStatusChip(
                    tone: learnedVoiceCount > 0 ? .ready : .muted,
                    text: "\(learnedVoiceCount) learned voice\(learnedVoiceCount == 1 ? "" : "s")"
                )
                runtimeChip
                Spacer(minLength: 0)
                Menu {
                    Button("Check Speaker Setup", systemImage: "checkmark.seal") {
                        Task { await model.checkSpeakerRuntime() }
                    }
                    .disabled(model.checkingSpeakerRuntime)
                    Button("Choose Python Environment…", systemImage: "folder") {
                        model.chooseSpeakerPython()
                    }
                    if model.errorDetails != nil {
                        Button("Copy Debug Details", systemImage: "doc.on.doc") {
                            model.copyErrorDetails()
                        }
                    }
                } label: {
                    Label("Speaker setup", systemImage: "wrench.and.screwdriver")
                        .font(CR.Font.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Check or repair the local speaker detection runtime")
            }
        }
        .padding(CR.Space.screen)
    }

    @ViewBuilder
    private var runtimeChip: some View {
        if model.checkingSpeakerRuntime {
            CRStatusChip(tone: .working, text: "Checking setup…")
        } else if isRuntimeHealthy {
            CRStatusChip(tone: .ready, text: "Speaker detection ready")
        } else if !hasCheckedRuntime {
            // The check loads a local model and takes a few seconds. Until it has run, the honest
            // state is "not checked", not a red failure: the old chip announced that setup was
            // broken on every open, then corrected itself a moment later.
            CRStatusChip(tone: .muted, text: "Not checked yet")
        } else {
            CRStatusChip(tone: .failed, text: "Speaker detection needs setup")
        }
    }

    private var hasCheckedRuntime: Bool {
        model.speakerRuntimeMessage != "Speaker setup has not been checked."
    }

    /// The runtime message is a sentence, so the chip reads the front of it rather than trying to
    /// fit the whole diagnostic into a pill.
    private var isRuntimeHealthy: Bool {
        let message = model.speakerRuntimeMessage.lowercased()
        return message.contains("ready") || message.contains("available")
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CR.Space.section) {
                if !retryableIssues.isEmpty {
                    retrySection
                }
                if reviewCallIDs.isEmpty && retryableIssues.isEmpty {
                    CREmptyState(
                        icon: "person.crop.circle.badge.questionmark",
                        title: "Nothing to review",
                        message: "After the next call, its voices appear here. One clear confirmation teaches the app a voice; two let it name that person automatically."
                    )
                }
                ForEach(reviewCallIDs, id: \.self) { callID in
                    callSection(callID)
                }
                if !missingAudioIssues.isEmpty {
                    missingAudioSection
                }
                Text("Audio stays until you name each voice or choose Keep Anonymous. All voice matching runs locally.")
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Ink.readable)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(CR.Space.screen)
        }
    }

    @ViewBuilder
    private func callSection(_ callID: CallID) -> some View {
        let reviews = listedReviews(for: callID)
        VStack(alignment: .leading, spacing: CR.Space.inner) {
            CRSectionHeader(callDate(callID)) {
                HStack(spacing: CR.Space.inner) {
                    Text(callProgress(callID))
                        .font(CR.Font.caption)
                        .foregroundStyle(CR.Ink.readable)
                    CRIconButton(
                        icon: "doc.text",
                        label: "Open transcript",
                        alwaysVisible: true,
                        trailingAligned: true
                    ) {
                        model.openTranscript(for: callID)
                    }
                }
            }
            callRoster(callID)
            callVoiceCount(callID)
            speakerTimeline(callID)
            ForEach(reviews) { review in
                reviewCard(review)
                    .id(review.clusterID)
            }
        }
    }

    /// The call's voices against its recording, above the cards that name them.
    ///
    /// A row per voice, a bar wherever that voice was heard, and a click that plays the bar. The
    /// rows carry the same colours as the cards below, so the voice being named is the voice that
    /// was heard. A call the separation found no voice in has no rows and shows nothing here.
    @ViewBuilder
    private func speakerTimeline(_ callID: CallID) -> some View {
        if let timeline = model.speakerTimelines[callID], !timeline.isEmpty {
            SpeakerTimelineView(
                timeline: timeline,
                audioURL: model.speakerCallAudioURLs[callID],
                playback: playback,
                selectedClusterID: selectedClusterID,
                onSelect: { clusterID in
                    selectedClusterID = clusterID
                }
            )
        }
    }

    /// How many voices this call was separated into, and a way to ask for a different number.
    ///
    /// The count is the one lever on how the detector behaves, and it is what explains a call whose
    /// voices came out wrong in either direction: two voices where one person spoke, or one voice
    /// holding two people. The number here is used for this call ahead of the people on it, and the
    /// audio is separated again from the copy the call kept.
    @ViewBuilder
    private func callVoiceCount(_ callID: CallID) -> some View {
        let counts = voiceCount(callID)
        let waiting = model.speakerReviews.filter { $0.callID == callID }.count
        // The number the stepper separates into. A call whose voices have all been named still has
        // a count, and a call whose voices are waiting has one too; the count of reviews alone was
        // wrong in both directions, because the reviews are only the voices left to name.
        let detected = max(counts.total, waiting)
        let issue = model.speakerAnalysisIssues.first { $0.callID == callID }
        let available = issue?.audioAvailable ?? true
        // The audio is there and the call cannot be retried: the only thing that means is a pass
        // over this call that is already running.
        let busy = available && !(issue?.canRetry ?? true)
        if detected > 0 {
            HStack(alignment: .firstTextBaseline, spacing: CR.Space.snug) {
                Text(
                    waiting > 0
                        ? "\(counts.named) of \(counts.total) voices named"
                        : "\(counts.total) voice\(counts.total == 1 ? "" : "s") detected"
                )
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Ink.readable)
                Stepper(value: voiceCountBinding(callID, detected: detected), in: 1...24) {
                    Text("\(voiceCounts[callID] ?? detected)")
                        .font(CR.Font.caption)
                        .monospacedDigit()
                }
                .fixedSize()
                .disabled(!available || busy)
                CRButton(
                    title: busy ? "Separating…" : "Separate again",
                    icon: "person.2.badge.gearshape",
                    help: available
                        ? "Separates the voices of this call again, into the number shown. "
                            + "The count wins over the people on the call."
                        : "The audio of this call has been given up, so its voices cannot be "
                            + "separated again."
                ) {
                    Task {
                        await model.redetectSpeakers(
                            for: callID,
                            voices: voiceCounts[callID] ?? detected
                        )
                    }
                }
                .disabled(!available || busy)
                if waiting > 0 {
                    CRStatusChip(tone: .waiting, text: "\(waiting) to name")
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The number of voices for a call: what the person chose, or what the detector found.
    private func voiceCountBinding(_ callID: CallID, detected: Int) -> Binding<Int> {
        Binding(
            get: { voiceCounts[callID] ?? detected },
            set: { voiceCounts[callID] = $0 }
        )
    }

    /// Who was on the call, in front of the voices that need naming.
    ///
    /// Naming a voice is a matching problem: the user has transcript samples and a list of people,
    /// and has to pair them. The window showed the samples and left the people to a menu that only
    /// opened on a click, so the pairing had to be done from memory. Three names on the surface,
    /// where the samples are, is the context the menu was hiding.
    @ViewBuilder
    private func callRoster(_ callID: CallID) -> some View {
        let people = model.callParticipants[callID] ?? []
        if !people.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: CR.Space.snug) {
                Text("On this call")
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Ink.readable)
                Text(people.map(\.name).joined(separator: " · "))
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Ink.readable)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func sortedReviews(for callID: CallID) -> [SpeakerReviewItem] {
        // The longest speaker is the most useful one to name first, so the busiest unknown voice
        // is not buried under a one-line cameo.
        model.speakerReviews
            .filter { $0.callID == callID }
            .sorted {
                if $0.speechDurationMilliseconds != $1.speechDurationMilliseconds {
                    return $0.speechDurationMilliseconds > $1.speechDurationMilliseconds
                }
                return $0.speakerIndex < $1.speakerIndex
            }
    }

    /// The cards this call shows: its voices still waiting, and the one the user clicked.
    ///
    /// A voice named on an earlier pass has no card, and a row on the picture that opened nothing
    /// would be a control that does nothing. Clicking such a row puts its card at the top, where
    /// the picture is: the samples to listen to, the name to change, and the way back to review.
    private func listedReviews(for callID: CallID) -> [SpeakerReviewItem] {
        SpeakerReviewList.cards(
            waiting: sortedReviews(for: callID),
            selected: selectedClusterID.flatMap { model.speakerReviewsByCluster[$0] },
            callID: callID
        )
    }

    // MARK: - One voice

    @ViewBuilder
    private func reviewCard(_ review: SpeakerReviewItem) -> some View {
        let busy = model.reviewingSpeakerIDs.contains(review.clusterID)
        let isSelected = review.clusterID == selectedClusterID
        VStack(alignment: .leading, spacing: CR.Space.item) {
            cardHeader(review)
            transcriptSamples(review)
            cardActions(review, busy: busy)
        }
        .padding(CR.Space.section)
        .crSurface(.rounded(CR.Radius.large))
        .opacity(busy ? 0.65 : 1)
        // The row that was clicked and the card it opened are one thing, so the card carries the
        // same mark the row does.
        .overlay(
            RoundedRectangle(cornerRadius: CR.Radius.large, style: .continuous)
                .strokeBorder(CR.Ink.action, lineWidth: isSelected ? 2 : 0)
        )
    }

    /// Whether this voice already has a person on it.
    private func isDecided(_ review: SpeakerReviewItem) -> Bool {
        review.state == .confirmed || review.state == .automatic
    }

    private func cardHeader(_ review: SpeakerReviewItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CR.Space.inner) {
            // The colour this voice is drawn in on the timeline, so a card and its row read as the
            // same voice.
            Circle()
                .fill(voiceColor(review))
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0.height - 2 }
            Text(displayLabel(review))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
            Text(formattedDuration(review.speechDurationMilliseconds) + " of speech")
                .font(CR.Font.caption)
                .foregroundStyle(CR.Ink.readable)
            // A voice the picture shows under a name has no card of its own until it is clicked,
            // and then the card has to say which name is being corrected.
            if isDecided(review), let named = participant(review.suggestedParticipantID) {
                CRStatusChip(tone: .ready, text: "Named \(named.name)", compact: true)
            }
            Spacer(minLength: CR.Space.inner)
            if let likely = participant(review.suggestedParticipantID) {
                Button {
                    selections[review.clusterID] = likely.id
                } label: {
                    HStack(spacing: CR.Space.snug) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Sounds like \(likely.name)")
                            .font(CR.Font.caption)
                    }
                    .foregroundStyle(CR.Tone.ready.ink)
                    .padding(.horizontal, CR.Space.inner)
                    // The same pill as a status chip, so it takes the chip's own inset. At its
                    // own three points it stood one point taller than the chip it sits beside.
                    .padding(.vertical, CR.Chip.insetY)
                    .background(CR.Tone.ready.color.opacity(0.14), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Use this suggestion")
                .accessibilityLabel("Use suggestion \(likely.name)")
            } else {
                Text("No match yet")
                    .font(CR.Font.caption.italic())
                    .foregroundStyle(CR.Ink.readable)
            }
        }
    }

    @ViewBuilder
    private func transcriptSamples(_ review: SpeakerReviewItem) -> some View {
        if let evidence = model.speakerReviewEvidence[review.clusterID] {
            if evidence.excerpts.isEmpty {
                Label("Transcript sample unavailable", systemImage: "text.badge.xmark")
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Ink.readable)
            } else {
                let limit = expandedSpeakers.contains(review.clusterID) ? 8 : 3
                VStack(spacing: CR.Space.snug) {
                    ForEach(Array(evidence.excerpts.prefix(limit).enumerated()), id: \.offset) { index, excerpt in
                        excerptCard(review, evidence: evidence, excerpt: excerpt, index: index)
                    }
                }
                if evidence.excerpts.count > 3 {
                    Button(
                        expandedSpeakers.contains(review.clusterID)
                            ? "Show fewer samples"
                            : "Show \(evidence.excerpts.count - 3) more sample\(evidence.excerpts.count - 3 == 1 ? "" : "s")"
                    ) {
                        if !expandedSpeakers.insert(review.clusterID).inserted {
                            expandedSpeakers.remove(review.clusterID)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Ink.action)
                }
                if evidence.audioURL == nil {
                    Label(
                        "Audio sample unavailable — source audio was already cleaned up",
                        systemImage: "speaker.slash"
                    )
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Ink.readable)
                }
            }
        } else {
            // Evidence loads after the review list. Saying so keeps the card from looking broken
            // and, more importantly, keeps the Confirm button usable in the meantime.
            HStack(spacing: CR.Space.snug) {
                ProgressView().controlSize(.small)
                Text("Loading samples…")
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Ink.readable)
            }
        }
    }

    private func excerptCard(
        _ review: SpeakerReviewItem,
        evidence: SpeakerReviewPlayback.Evidence,
        excerpt: SpeakerReviewPlayback.Excerpt,
        index: Int
    ) -> some View {
        let playing = playingClusterID == review.clusterID && playingSampleStart == excerpt.startMs
        let moved = SpeakerReviewPlayback.override(for: excerpt, in: evidence.overrides)
        return HStack(alignment: .top, spacing: CR.Space.inner) {
            VStack(alignment: .leading, spacing: CR.Space.snug) {
                HStack(spacing: CR.Space.snug) {
                    Text(excerptLabel(index: index, excerpt: excerpt))
                        .font(CR.Font.caption)
                        .foregroundStyle(CR.Ink.readable)
                    // Where these lines went, said on the lines themselves. The voice keeps its own
                    // name, so without this the card would read as though the assignment had not
                    // landed, and the person who moved them would move them again.
                    if let moved {
                        CRStatusChip(tone: .ready, text: "Moved to \(moved.speakerName)", compact: true)
                    }
                }
                Text(excerpt.text)
                    .font(CR.Font.body)
                    .textSelection(.enabled)
                    // A long turn can run to a full screen. The sample only has to be long
                    // enough to recognise the voice, and the whole transcript is one click away.
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(
                        "Transcript sample for \(displayLabel(review)): \(excerpt.text)"
                    )
            }
            Spacer(minLength: 0)
            // One control per excerpt, because one voice is often several people: two colleagues
            // sharing a headset arrive as one voice, and a voice is offered one name. Reading the
            // sample is what tells them apart, so the answer is attached to the sample.
            excerptMoveMenu(review, excerpt: excerpt, moved: moved)
            if model.speakerCallAudioURLs[review.callID] != nil {
                CRIconButton(
                    icon: playing ? "stop.fill" : "play.fill",
                    label: playing ? "Stop excerpt" : "Play excerpt",
                    tone: .working,
                    alwaysVisible: playing,
                    revealed: true,
                    // The excerpt's text starts on the card's left gutter, so the play glyph ends
                    // on the right one. Centred in its circle it sat half an icon inside it, and
                    // the card read as though its right margin were twice its left.
                    trailingAligned: true
                ) {
                    toggleSample(review, excerpt: excerpt)
                }
            }
        }
        .padding(CR.Space.inner)
        .background(
            RoundedRectangle(cornerRadius: CR.Radius.small, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    /// The control that moves one excerpt onto a person.
    ///
    /// A menu rather than a picker: an excerpt is not a voice, so it has no remembered choice and
    /// no Confirm of its own. Choosing a name does the whole job, and the same menu is how an
    /// assignment already made is taken back.
    @ViewBuilder
    private func excerptMoveMenu(
        _ review: SpeakerReviewItem,
        excerpt: SpeakerReviewPlayback.Excerpt,
        moved: SpeakerLineOverride?
    ) -> some View {
        let busy = model.isMovingSpeakerExcerpt(excerpt)
        HStack(spacing: CR.Space.tight) {
            ParticipantPicker(
                participants: candidateParticipants(for: review),
                onSelect: { participant in
                    model.assignSpeakerExcerpt(
                        review,
                        excerpt: excerpt,
                        participantID: participant.id
                    )
                },
                create: { name in
                    await model.createParticipant(name: name, role: "", company: "", email: "")
                },
                note: { participant in
                    notes(for: participant, on: review)
                }
            ) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CR.Ink.readable)
                    .frame(width: CR.Icon.circle, height: CR.Icon.circle)
                    .contentShape(Circle())
            }
            .frame(width: CR.Icon.circle)
            .disabled(busy)
            .help(
                moved == nil
                    ? "Assign these lines to someone else"
                    : "Change who these lines belong to"
            )
            .accessibilityLabel("Assign these lines to another participant")
            if moved != nil {
                Button {
                    model.clearSpeakerExcerpt(review, excerpt: excerpt)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CR.Ink.readable)
                        .frame(width: CR.Icon.circle, height: CR.Icon.circle)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .help("Follow the voice again")
                .accessibilityLabel("Put these lines back with the voice")
            }
        }
    }

    private func cardActions(_ review: SpeakerReviewItem, busy: Bool) -> some View {
        VStack(alignment: .leading, spacing: CR.Space.snug) {
            HStack(spacing: CR.Space.inner) {
                // A search field rather than a menu: a library of a few hundred people turned the
                // menu into a list to read through while the call is still running. This one is
                // typed into, leads with the people on this call, and adds a new person from the
                // same field, so both ways of naming a voice start with the same keystrokes.
                ParticipantPicker(
                    participants: candidateParticipants(for: review),
                    onSelect: { participant in
                        selections[review.clusterID] = participant.id
                    },
                    create: { name in
                        await model.createParticipant(name: name, role: "", company: "", email: "")
                    },
                    note: { participant in
                        notes(for: participant, on: review)
                    }
                ) {
                    participantPill(for: review)
                }
                .accessibilityLabel("Participant for \(displayLabel(review))")

                CRButton(
                    title: busy ? "Saving…" : (isDecided(review) ? "Reassign" : "Confirm"),
                    icon: busy ? nil : "checkmark",
                    kind: .primary
                ) {
                    guard let participantID = selection(for: review).wrappedValue else { return }
                    model.confirmSpeaker(review, participantID: participantID)
                }
                .disabled(selection(for: review).wrappedValue == nil || busy)
                .help(confirmHelp(review))
                .accessibilityLabel("Confirm \(displayLabel(review))")

                if isDecided(review) {
                    // The only way back for a name that was decided on an earlier pass. Without it
                    // a wrong name on the picture was permanent.
                    CRButton(title: "Return to review", kind: .secondary) {
                        model.returnSpeakerToReview(clusterID: review.clusterID)
                    }
                    .disabled(busy)
                    .help("Takes the name off this voice and puts it back among the voices to name.")
                    .accessibilityLabel("Return \(displayLabel(review)) to review")
                } else {
                    CRButton(title: "Keep Anonymous", kind: .secondary) {
                        model.keepSpeakerUnknown(review)
                    }
                    .disabled(busy)
                    .accessibilityLabel("Keep \(displayLabel(review)) anonymous")
                }
            }
            if let taken = alreadyNamedWarning(for: review) {
                Label(taken, systemImage: "person.2.badge.gearshape")
                    .font(CR.Font.caption)
                    .foregroundStyle(CR.Tone.waiting.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Explains a disabled Confirm, which is the difference between "broken" and "choose a name".
    private func confirmHelp(_ review: SpeakerReviewItem) -> String {
        if selection(for: review).wrappedValue == nil {
            return "Choose a participant first."
        }
        if let participantID = selection(for: review).wrappedValue,
           let participant = participant(participantID) {
            return model.reviewingSpeakerIDs.contains(review.clusterID)
                ? "Saving…"
                : "Name this voice \(participant.name) and learn it."
        }
        return "Confirm this voice."
    }

    // MARK: - Repairs

    private var retryableIssues: [SpeakerAnalysisIssue] {
        model.speakerAnalysisIssues.filter(\.audioAvailable)
    }

    private var missingAudioIssues: [SpeakerAnalysisIssue] {
        model.speakerAnalysisIssues.filter { !$0.audioAvailable }
    }

    private var retrySection: some View {
        VStack(alignment: .leading, spacing: CR.Space.inner) {
            CRSectionHeader("Calls needing speaker detection")
            ForEach(retryableIssues) { issue in
                CRCallout(
                    icon: "waveform.badge.exclamationmark",
                    title: issue.startedAt.formatted(date: .abbreviated, time: .shortened),
                    message: issue.message,
                    tone: .failed
                ) {
                    HStack(spacing: CR.Space.inner) {
                        CRButton(title: "Retry Detection", kind: .primary) {
                            Task { await model.retrySpeakerAnalysis(for: issue.callID) }
                        }
                        .disabled(!issue.canRetry)
                        CRButton(title: "Open Transcript", icon: "doc.text") {
                            model.openTranscript(for: issue.callID)
                        }
                        if issue.details != nil {
                            CRButton(title: "Copy Debug Details", icon: "doc.on.doc") {
                                model.copyErrorDetails()
                            }
                        }
                    }
                }
            }
        }
    }

    private var missingAudioSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: CR.Space.item) {
                ForEach(missingAudioIssues) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: CR.Space.inner) {
                        VStack(alignment: .leading, spacing: CR.Space.hairline) {
                            Text(issue.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(CR.Font.body)
                            Text(issue.message)
                                .font(CR.Font.caption)
                                .foregroundStyle(CR.Ink.readable)
                        }
                        Spacer(minLength: CR.Space.inner)
                        CRButton(title: "Open Transcript", icon: "doc.text") {
                            model.openTranscript(for: issue.callID)
                        }
                    }
                }
            }
            .padding(.top, CR.Space.snug)
        } label: {
            Text("Older calls without audio (\(missingAudioIssues.count))")
                .font(CR.Font.callout)
                .foregroundStyle(CR.Ink.readable)
        }
    }

    // MARK: - Blocked state

    /// The window while the key has not been read yet.
    ///
    /// Two waits look the same from here and are not: a read that has just started, and a read
    /// parked on a permission dialog that macOS will wait on forever. Only the second one needs
    /// the user to do something, and it is also the one that is invisible, so the two are worded
    /// differently.
    @ViewBuilder
    private var voiceIdentityWaiting: some View {
        VStack {
            if model.voiceIdentityState == .waitingForPermission {
                CRCallout(
                    icon: "lock.trianglebadge.exclamationmark",
                    title: "Waiting for keychain permission",
                    message: "macOS is waiting for an answer to a dialog asking whether Call Recorder "
                        + "may read its key. Look on every display: the dialog can open behind "
                        + "another window or on another screen, where it is easy to miss. Choose "
                        + "Always Allow rather than Allow, or the question returns.",
                    tone: .waiting
                ) {
                    CRButton(title: "Try Again", icon: "arrow.clockwise", kind: .primary) {
                        model.retryVoiceIdentity()
                    }
                }
            } else {
                HStack(spacing: CR.Space.inner) {
                    ProgressView().controlSize(.small)
                    Text("Reading the voice-profile key…")
                        .font(CR.Font.body)
                        .foregroundStyle(CR.Ink.readable)
                }
                .padding(CR.Space.section)
            }
            Spacer(minLength: 0)
        }
        .padding(CR.Space.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func voiceIdentityUnavailable(_ error: String) -> some View {
        VStack {
            CRCallout(
                icon: "lock.trianglebadge.exclamationmark",
                title: "Voice identity is locked",
                message: "Unlock your login keychain, then retry. Past transcripts are not affected.",
                tone: .failed
            ) {
                VStack(alignment: .leading, spacing: CR.Space.snug) {
                    CRButton(title: "Retry Voice Identity", icon: "arrow.clockwise", kind: .primary) {
                        model.retryVoiceIdentity()
                    }
                    Text(error)
                        .font(CR.Font.caption)
                        .foregroundStyle(CR.Ink.readable)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(CR.Space.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var backgroundWash: some View {
        if #available(macOS 26.0, *) {
            Color.clear
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    // MARK: - Derived

    private var totalPendingVoices: Int {
        model.speakerReviews.filter { $0.state != .confirmed && $0.state != .automatic }.count
    }

    private var learnedVoiceCount: Int {
        model.voiceProfileSummaries.filter { $0.confirmedSampleCount > 0 }.count
    }

    private var reviewCallIDs: [CallID] {
        var seen = Set<CallID>()
        return model.speakerReviews.compactMap { seen.insert($0.callID).inserted ? $0.callID : nil }
    }

    private func callProgress(_ callID: CallID) -> String {
        let counts = voiceCount(callID)
        let spoken = formattedDuration(callSpeechDuration(callID))
        return "\(counts.named) of \(counts.total) named · \(spoken)"
    }

    private func callDate(_ callID: CallID) -> String {
        model.recentCalls.first { $0.id == callID }?.startedAt.formatted(date: .abbreviated, time: .shortened)
            ?? model.speakerReviewCallDates[callID]?.formatted(date: .abbreviated, time: .shortened)
            ?? model.speakerReviews.first { $0.callID == callID }?.createdAt.formatted(
                date: .abbreviated, time: .shortened)
            ?? "Call"
    }

    private func callSpeechDuration(_ callID: CallID) -> Int {
        model.speakerReviews
            .filter { $0.callID == callID }
            .reduce(0) { $0 + $1.speechDurationMilliseconds }
    }

    /// How many voices the call's transcript holds, and how many of them carry a name.
    ///
    /// The stored count is read from the call's transcript while the window loads its evidence. The
    /// fallback covers the moment before that read finishes: the reviews are the voices still
    /// waiting, and a voice on that list has no name yet by definition.
    private func voiceCount(_ callID: CallID) -> SpeakerVoiceCount {
        if let stored = model.speakerVoiceCounts[callID] { return stored }
        let reviews = model.speakerReviews.filter { $0.callID == callID }
        return SpeakerVoiceCount(named: 0, total: reviews.count)
    }

    /// Names the people already given a voice in this call, so a second voice is not handed to
    /// the same person. The name stays selectable, because two speakers can be one person on two
    /// devices.
    /// What the picker says beside a name: who is on this call, and who has already been given to
    /// another voice.
    private func notes(for participant: Participant, on review: SpeakerReviewItem) -> String? {
        var notes: [String] = []
        if wasOnCall(participant, review: review) { notes.append("on this call") }
        if model.namedParticipants[review.callID]?.contains(participant.id) == true {
            notes.append("already named")
        }
        return notes.isEmpty ? nil : notes.joined(separator: ", ")
    }

    /// The picker's own control: the chosen name, or what it says when nothing is chosen yet.
    private func participantPill(for review: SpeakerReviewItem) -> some View {
        let chosen = participant(selection(for: review).wrappedValue)
        return CRFieldBox {
            HStack(spacing: CR.Space.snug) {
                Text(chosen?.name ?? "Choose participant…")
                    .font(CR.Font.body)
                    .foregroundStyle(CR.Ink.readable)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CR.Ink.mark)
            }
            .frame(width: 240, alignment: .leading)
        }
    }

    /// The people who were on the call, before everyone else.
    ///
    /// Naming a remote voice means choosing from the people who were on the call it came from, and
    /// that is a handful. The picker listed everyone ever met instead, in name order, so on a call
    /// with three people the answer sat somewhere in forty-seven and the three who were actually
    /// there were not marked. The call's own people now come first and say whose call they were on;
    /// a remote voice is one of them unless it is someone new, so the long tail stays reachable
    /// without being the first thing to read.
    private func candidateParticipants(for review: SpeakerReviewItem) -> [Participant] {
        SpeakerReviewCandidates.ordered(
            participants: model.participants,
            onCall: model.callParticipants[review.callID] ?? []
        )
    }

    private func wasOnCall(_ participant: Participant, review: SpeakerReviewItem) -> Bool {
        SpeakerReviewCandidates.wasOnCall(
            participant,
            onCall: model.callParticipants[review.callID] ?? []
        )
    }

    /// The warning only appears for a person who is already named and is not the current choice.
    private func alreadyNamedWarning(for review: SpeakerReviewItem) -> String? {
        guard
            let participantID = selection(for: review).wrappedValue,
            model.namedParticipants[review.callID]?.contains(participantID) == true,
            let participant = participant(participantID)
        else { return nil }
        return "\(participant.name) is already named on another voice in this call."
    }

    /// The first excerpt is the opening turn of the call, which is where people greet each other
    /// and often say their own name. Naming that in the label is the fastest way to place a voice.
    private func excerptLabel(index: Int, excerpt: SpeakerReviewPlayback.Excerpt) -> String {
        let time = clockTime(excerpt.startMs)
        return index == 0 ? "Opening · \(time)" : "Excerpt \(index + 1) · \(time)"
    }

    private var speakerFailurePresented: Binding<Bool> {
        Binding(
            get: { model.speakerReviewFailure != nil },
            set: { if !$0 { model.dismissSpeakerReviewFailure() } }
        )
    }

    private var playbackErrorPresented: Binding<Bool> {
        Binding(
            get: { playbackError != nil },
            set: { if !$0 { playbackError = nil } }
        )
    }

    // MARK: - Playback

    /// Plays one sample of a voice, from the picture the user is looking at.
    ///
    /// The recording plays through the shared player, so the playhead moves onto the timeline and
    /// the words are heard where they were said. The clip the card used to play on its own was cut
    /// from the recording with the silence taken out, and the playhead stayed where it was: the
    /// sample and the picture could not be about the same moment.
    private func toggleSample(_ review: SpeakerReviewItem, excerpt: SpeakerReviewPlayback.Excerpt) {
        if playingClusterID == review.clusterID && playingSampleStart == excerpt.startMs {
            stopPlayback()
            return
        }
        stopPlayback()
        guard let audioURL = model.speakerCallAudioURLs[review.callID] else {
            playbackError = "The audio of this call is no longer on disk."
            return
        }
        playback.load(audioURL)
        if let failure = playback.failure {
            playbackError = failure
            return
        }
        playingClusterID = review.clusterID
        playingSampleStart = excerpt.startMs
        listeningPass = SpeakerTimeline.ListeningPass(
            runs: model.speakerTimelines[review.callID]?.lane(for: review.clusterID)?.runs ?? [],
            startMs: excerpt.startMs,
            endMs: excerpt.endMs
        )
        playback.play(fromMs: excerpt.startMs)
    }

    /// Skips the listening that is not this voice's, and ends the sample where it ends.
    ///
    /// A voice speaks at minute five and again at minute nine, and the sample of its first turn
    /// used to play the four minutes in between. The runs the picture draws are what says which
    /// parts are this voice's, so the playhead moves to the next of them instead of playing on.
    private func skipPauses(at positionMs: Int) {
        guard let listeningPass else { return }
        switch listeningPass.step(at: positionMs) {
        case .playOn: return
        case .finished: stopPlayback()
        case let .jump(toMs): playback.seek(toMs: toMs)
        }
    }

    private func stopPlayback() {
        playback.pause()
        listeningPass = nil
        playingClusterID = nil
        playingSampleStart = nil
    }

    // MARK: - Selection

    private func selection(for review: SpeakerReviewItem) -> Binding<ParticipantID?> {
        Binding(
            get: { selections[review.clusterID] },
            set: { selections[review.clusterID] = $0 }
        )
    }

    private func participant(_ id: ParticipantID?) -> Participant? {
        guard let id else { return nil }
        return model.participants.first { $0.id == id }
    }

    private func seedSelections() {
        for review in model.speakerReviews {
            if let suggested = review.suggestedParticipantID, selections[review.clusterID] == nil {
                selections[review.clusterID] = suggested
            }
        }
    }

    /// Where the excerpt sits in the recording, so the same words can be found in the audio or
    /// in the transcript while the voice is being identified.
    private func clockTime(_ milliseconds: Int) -> String {
        let total = max(0, milliseconds / 1_000)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private func formattedDuration(_ milliseconds: Int) -> String {
        Duration.milliseconds(milliseconds).formatted(.units(allowed: [.minutes, .seconds]))
    }

    /// Turns the diarizer's "SPEAKER_02" into "Speaker 2". The raw label is an internal
    /// identifier, and a person naming a voice should not have to read one.
    /// What this voice is called on its card.
    ///
    /// The number is the transcript's, so a card and the row it was opened from carry the same one,
    /// and the words of that voice in the saved transcript are numbered the same way. The stored
    /// label is the separation's own name for the voice and does not follow that count.
    private func displayLabel(_ review: SpeakerReviewItem) -> String {
        SpeakerVoiceName.numbered(review.speakerIndex)
    }

    /// The colour the timeline draws this voice in.
    ///
    /// The row's place is what decides the colour, so the two surfaces agree even on a call with
    /// more voices than the palette holds. A call the timeline has no row for, or a card drawn
    /// before the rows were read, falls back to the voice's own number.
    private func voiceColor(_ review: SpeakerReviewItem) -> Color {
        let row = model.speakerTimelines[review.callID]?
            .lanes.firstIndex { $0.speakerIndex == review.speakerIndex }
        return SpeakerPalette.color(at: row ?? review.speakerIndex)
    }
}
