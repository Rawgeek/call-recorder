import CallRecorderCore
import SwiftUI

/// The colours a voice is drawn in.
///
/// One colour follows one voice across the surfaces that show it: the bar on the timeline, the chip
/// that names the row, and the card that names the voice. Eight hues cover the voices a call holds
/// and a ninth row starts the list again, from a colour that has been off the screen for seven rows.
enum SpeakerPalette {
    static let colors: [Color] = [
        Color(red: 0.23, green: 0.51, blue: 0.96),
        Color(red: 0.87, green: 0.40, blue: 0.20),
        Color(red: 0.13, green: 0.70, blue: 0.36),
        Color(red: 0.85, green: 0.58, blue: 0.09),
        Color(red: 0.90, green: 0.30, blue: 0.60),
        Color(red: 0.10, green: 0.55, blue: 0.35),
        Color(red: 0.55, green: 0.36, blue: 0.93),
        Color(red: 0.85, green: 0.26, blue: 0.28),
    ]

    static func color(at index: Int) -> Color {
        guard !colors.isEmpty else { return .accentColor }
        let wrapped = ((index % colors.count) + colors.count) % colors.count
        return colors[wrapped]
    }
}

/// One call's voices drawn against its recording, with the recording under them.
///
/// Naming a voice is a listening task, and the picture is what makes it a short one: a row per
/// voice, a bar for every stretch it spoke, and a click that plays the bar. The rows carry the same
/// colours as the cards below, so the voice being named is the voice that was heard.
struct SpeakerTimelineView: View {
    let timeline: SpeakerTimeline
    var audioURL: URL?
    /// The player the window shares with the cards below.
    ///
    /// One recording, one player: pressing play on a sample has to move the playhead on the picture
    /// the user is looking at, and two players over the same audio would answer with two voices.
    /// A render passes nothing and gets a player of its own that is never started.
    var playback: CallPlayback?
    /// The voice whose card the window has opened below the picture.
    var selectedClusterID: SpeakerClusterID?
    /// Called when a row or one of its bars is clicked, with the voice behind it.
    var onSelect: ((SpeakerClusterID) -> Void)?

    @State private var ownPlayback = CallPlayback()
    @State private var zoom: Double = 1
    @State private var follows = true
    @State private var pinchStart: Double?
    @State private var scroll = ScrollPosition()
    @State private var containerWidth: CGFloat = 0
    @State private var offsetX: CGFloat = 0

    private let laneHeight: CGFloat = 22
    private let laneGap: CGFloat = 4
    private let rulerHeight: CGFloat = 18
    private let labelWidth: CGFloat = 112
    private let overviewHeight: CGFloat = 26
    /// How many rows are on screen at once. Every voice has a row: a call with more voices than
    /// this scrolls, where it used to draw the first eight and leave the rest off the picture
    /// entirely, which on 2026-09-24 hid two voices that were waiting to be named.
    private let maximumVisibleRows = 12

    var body: some View {
        VStack(alignment: .leading, spacing: CR.Space.item) {
            playerRow
            timelineHeader
            lanes
        }
        .padding(CR.Space.item)
        .crSurface(.rounded(CR.Radius.large))
        .task(id: audioURL) {
            guard let audioURL else { return }
            player.load(audioURL)
        }
        .onDisappear { player.pause() }
        .onChange(of: player.positionMs) { _, _ in followPlayhead() }
    }

    /// The recording this picture plays, whichever player the window handed over.
    private var player: CallPlayback { playback ?? ownPlayback }

    // MARK: - Derived

    /// The length the picture covers. The recording answers when it is longer than the words: a
    /// call that ends with four minutes of silence is drawn with that silence.
    private var durationMs: Int { max(1, max(timeline.durationMs, player.durationMs)) }

    private var rows: [SpeakerTimeline.Lane] { timeline.lanes }

    private var contentWidth: CGFloat { max(containerWidth, 1) * zoom }

    private var lanesHeight: CGFloat {
        max(0, CGFloat(rows.count) * (laneHeight + laneGap) - laneGap)
    }

    /// How much of the rows is on screen before the rest is scrolled to.
    private var visibleLanesHeight: CGFloat {
        guard rows.count > maximumVisibleRows else { return lanesHeight }
        return CGFloat(maximumVisibleRows) * (laneHeight + laneGap) - laneGap
    }

    private var tickStepMs: Int { TimelineTicks.step(durationMs: durationMs, width: contentWidth) }

    private func contentX(ofMs milliseconds: Int) -> CGFloat {
        CGFloat(milliseconds) / CGFloat(durationMs) * contentWidth
    }

    private func milliseconds(at x: CGFloat) -> Int {
        guard contentWidth > 0 else { return 0 }
        let ratio = min(max(0, x / contentWidth), 1)
        return Int(ratio * CGFloat(durationMs))
    }

    // MARK: - Player

    private var playerRow: some View {
        HStack(spacing: CR.Space.item) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: CR.Icon.circle, height: CR.Icon.circle)
                    .background(CR.Tone.working.color, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(player.url == nil || player.durationMs == 0)
            .help(player.isPlaying ? "Pause" : "Play the recording")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Text(timelineClock(player.positionMs))
                .font(CR.Font.caption.monospacedDigit())
                .foregroundStyle(CR.Ink.readable)

            positionTrack

            Text(timelineClock(durationMs))
                .font(CR.Font.caption.monospacedDigit())
                .foregroundStyle(CR.Ink.readable)

            if player.failure != nil {
                CRStatusChip(tone: .failed, text: "Recording unavailable")
                    .help("The audio file beside this call could not be opened. The words are safe.")
            }
        }
    }

    /// The position bar: a click or a drag moves the recording, as the system's own player does.
    private var positionTrack: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = Double(player.positionMs) / Double(durationMs)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: 5)
                Capsule()
                    .fill(CR.Tone.working.color)
                    .frame(width: width * min(max(fraction, 0), 1), height: 5)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 11, height: 11)
                    .offset(x: min(max(width * min(max(fraction, 0), 1) - 5.5, 0), width - 11))
            }
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = min(max(0, value.location.x / width), 1)
                        player.seek(toMs: Int(ratio * Double(durationMs)))
                    }
            )
        }
        .frame(height: 12)
        .frame(maxWidth: .infinity)
        .help("Drag to move through the recording")
    }

    // MARK: - Header

    private var timelineHeader: some View {
        HStack(spacing: CR.Space.snug) {
            Text("Timeline")
                .font(CR.Font.headline)
            Text("\(timelineClock(player.positionMs)) / \(timelineClock(durationMs))")
                .font(CR.Font.caption.monospacedDigit())
                .foregroundStyle(CR.Ink.readable)
            Spacer(minLength: CR.Space.inner)
            Toggle("Follow", isOn: $follows)
                .toggleStyle(.checkbox)
                .font(CR.Font.caption)
                .help("Keep the playhead on screen while the recording plays")
            CRIconButton(icon: "minus", label: "Zoom out", alwaysVisible: true) {
                setZoom(zoom / 1.6)
            }
            .disabled(zoom <= 1)
            Text(String(format: "%.1f×", zoom))
                .font(CR.Font.caption.monospacedDigit())
                .foregroundStyle(CR.Ink.readable)
                .frame(width: 36)
            CRIconButton(icon: "plus", label: "Zoom in", alwaysVisible: true) {
                setZoom(zoom * 1.6)
            }
            CRButton(title: "Fit", help: "Show the whole recording") {
                setZoom(1)
                scroll.scrollTo(x: 0)
            }
        }
    }

    // MARK: - Lanes

    private var lanes: some View {
        VStack(alignment: .leading, spacing: CR.Space.inner) {
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: CR.Space.inner) {
                    labelColumn
                    laneScroller
                }
            }
            .frame(height: rulerHeight + visibleLanesHeight)
            .scrollIndicators(rows.count > maximumVisibleRows ? .automatic : .hidden)
            overview
            hint
        }
    }

    private var labelColumn: some View {
        VStack(alignment: .leading, spacing: laneGap) {
            // The ruler sits above the first row, and the labels line up with the rows it rules.
            Color.clear.frame(width: labelWidth, height: rulerHeight)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, lane in
                laneChip(lane, color: SpeakerPalette.color(at: index))
            }
        }
        .frame(width: labelWidth, alignment: .leading)
    }

    /// One row's name, and the control that opens the row's card below the picture.
    ///
    /// The chip is a button whenever the window can name the voice, which is whenever the voice
    /// has a cluster behind it: clicking a row is how somebody who hears the wrong name reaches the
    /// one place that can change it.
    @ViewBuilder
    private func laneChip(_ lane: SpeakerTimeline.Lane, color: Color) -> some View {
        let isSelected = lane.clusterID != nil && lane.clusterID == selectedClusterID
        let chip = laneChipBody(lane, color: color)
            .frame(width: labelWidth, height: laneHeight, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(CR.Ink.action, lineWidth: isSelected ? 2 : 0)
                    .padding(-2)
            )
            .help(
                onSelect != nil && lane.clusterID != nil
                    ? "\(lane.label) spoke for \(timelineSpoken(lane.speakingMilliseconds)) · click to name or rename"
                    : "\(lane.label) spoke for \(timelineSpoken(lane.speakingMilliseconds))"
            )
        if let onSelect, let clusterID = lane.clusterID {
            Button {
                onSelect(clusterID)
            } label: {
                chip
            }
            .buttonStyle(.plain)
        } else {
            chip
        }
    }

    private func laneChipBody(_ lane: SpeakerTimeline.Lane, color: Color) -> some View {
        let speaking = lane.holds(player.positionMs)
        return HStack(spacing: CR.Space.snug) {
            Text(lane.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .padding(.horizontal, CR.Space.snug)
                .frame(height: laneHeight)
                .background(color.opacity(speaking ? 1 : 0.85), in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(speaking ? 0.9 : 0), lineWidth: 1.5)
                )
            Spacer(minLength: 0)
            Text(timelineSpoken(lane.speakingMilliseconds))
                .font(.system(size: 9))
                .foregroundStyle(CR.Ink.readable)
                .lineLimit(1)
        }
    }

    private var laneScroller: some View {
        ScrollView(.horizontal) {
            TimelineLanes(
                timeline: timeline,
                rows: rows,
                durationMs: durationMs,
                positionMs: player.positionMs,
                rulerHeight: rulerHeight,
                laneHeight: laneHeight,
                laneGap: laneGap,
                tickStepMs: tickStepMs
            )
            .frame(width: contentWidth, height: rulerHeight + lanesHeight)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                seek(to: location)
            }
        }
        .frame(height: rulerHeight + lanesHeight)
        .scrollIndicators(.hidden)
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.x
        } action: { _, offset in
            offsetX = offset
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.width
        } action: { _, width in
            containerWidth = width
        }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let start = pinchStart ?? zoom
                    pinchStart = start
                    setZoom(start * value.magnification)
                }
                .onEnded { _ in pinchStart = nil }
        )
        .onHover { hovering in
            guard hovering else {
                NSCursor.arrow.set()
                return
            }
            NSCursor.pointingHand.set()
        }
    }

    /// The whole recording in miniature, with the part on screen drawn on it.
    private var overview: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            Canvas { context, size in
                TimelineOverview.draw(
                    in: &context,
                    size: size,
                    timeline: timeline,
                    durationMs: durationMs,
                    positionMs: player.positionMs,
                    visible: CGRect(
                        x: offsetX / max(contentWidth, 1) * width,
                        y: 0,
                        width: containerWidth / max(contentWidth, 1) * width,
                        height: size.height
                    )
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = min(max(0, value.location.x / width), 1)
                        let centre = contentX(ofMs: Int(ratio * CGFloat(durationMs)))
                        scroll.scrollTo(
                            x: min(max(0, centre - containerWidth / 2), max(0, contentWidth - containerWidth))
                        )
                    }
            )
            .help("Drag to move the part of the recording on screen")
        }
        .frame(height: overviewHeight)
    }

    private var hint: some View {
        Text(
            "Click a name to open its samples · click a bar to jump there · scroll to pan "
                + "· pinch or − and + to zoom"
        )
            .font(CR.Font.caption)
            .foregroundStyle(CR.Ink.readable)
    }

    // MARK: - Actions

    /// Zooms about the middle of what is on screen, so zooming in does not lose the place.
    private func setZoom(_ value: Double) {
        let clamped = min(max(1, value), 40)
        guard abs(clamped - zoom) > 0.001 else { return }
        let centreMs = milliseconds(at: offsetX + containerWidth / 2)
        zoom = clamped
        let x = contentX(ofMs: centreMs) - containerWidth / 2
        scroll.scrollTo(x: min(max(0, x), max(0, contentWidth - containerWidth)))
    }

    /// Clicking a bar plays that bar; clicking anywhere else moves the recording there.
    private func seek(to location: CGPoint) {
        let scale = contentWidth / CGFloat(durationMs)
        guard scale > 0 else { return }
        let milliseconds = Int(location.x / scale)
        let row = Int((location.y - rulerHeight) / (laneHeight + laneGap))
        if row >= 0, row < rows.count,
            let run = rows[row].runs.last(where: { $0.startMs <= milliseconds }),
            run.holds(milliseconds)
        {
            select(rows[row])
            player.play(fromMs: run.startMs)
            return
        }
        player.seek(toMs: milliseconds)
    }

    /// Tells the window which voice was clicked, when the row has one behind it.
    private func select(_ lane: SpeakerTimeline.Lane) {
        guard let onSelect, let clusterID = lane.clusterID else { return }
        onSelect(clusterID)
    }

    /// Keeps the playhead where it can be seen, once the user asked for that.
    ///
    /// A scroll of their own turns the follow switch off, which is the same rule the live
    /// transcript follows: a view that pulls itself back while somebody is reading is worse than
    /// one that stops moving.
    private func followPlayhead() {
        guard follows, player.isPlaying, containerWidth > 0 else { return }
        let x = contentX(ofMs: player.positionMs)
        let margin = containerWidth * 0.2
        guard x < offsetX + margin || x > offsetX + containerWidth - margin else { return }
        scroll.scrollTo(x: min(max(0, x - containerWidth / 2), max(0, contentWidth - containerWidth)))
    }
}

/// The ruler and the bars, drawn in one canvas so a row and its label line up exactly.
private struct TimelineLanes: View {
    let timeline: SpeakerTimeline
    let rows: [SpeakerTimeline.Lane]
    let durationMs: Int
    let positionMs: Int
    let rulerHeight: CGFloat
    let laneHeight: CGFloat
    let laneGap: CGFloat
    let tickStepMs: Int

    var body: some View {
        Canvas { context, size in
            let scale = size.width / CGFloat(max(1, durationMs))
            drawGrid(in: &context, size: size, scale: scale)
            drawRuler(in: &context, size: size, scale: scale)
            drawRows(in: &context, size: size, scale: scale)
            drawPlayhead(in: &context, size: size, scale: scale)
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize, scale: CGFloat) {
        var x: CGFloat = 0
        while x <= size.width {
            let line = Path { path in
                path.move(to: CGPoint(x: x, y: rulerHeight))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(line, with: .color(Color.primary.opacity(0.10)), lineWidth: 1)
            x += CGFloat(tickStepMs) * scale
        }
    }

    private func drawRuler(in context: inout GraphicsContext, size: CGSize, scale: CGFloat) {
        var milliseconds = 0
        while CGFloat(milliseconds) * scale <= size.width {
            let label = Text(timelineClock(milliseconds))
                .font(.system(size: 9))
                .foregroundStyle(Color.secondary)
            context.draw(
                label,
                at: CGPoint(x: CGFloat(milliseconds) * scale + 4, y: rulerHeight / 2),
                anchor: .leading
            )
            milliseconds += tickStepMs
        }
    }

    private func drawRows(in context: inout GraphicsContext, size: CGSize, scale: CGFloat) {
        for (index, lane) in rows.enumerated() {
            let y = rulerHeight + CGFloat(index) * (laneHeight + laneGap)
            let strip = Path(
                roundedRect: CGRect(x: 0, y: y, width: size.width, height: laneHeight),
                cornerRadius: 4
            )
            context.fill(strip, with: .color(Color.primary.opacity(0.06)))
            let color = SpeakerPalette.color(at: index)
            for run in lane.runs {
                let bar = CGRect(
                    x: CGFloat(run.startMs) * scale,
                    y: y,
                    width: max(2, CGFloat(run.durationMs) * scale),
                    height: laneHeight
                )
                let path = Path(roundedRect: bar, cornerRadius: 4)
                context.fill(path, with: .color(color))
                if run.holds(positionMs) {
                    context.stroke(path, with: .color(.white.opacity(0.95)), lineWidth: 2)
                }
            }
        }
    }

    private func drawPlayhead(in context: inout GraphicsContext, size: CGSize, scale: CGFloat) {
        let x = CGFloat(positionMs) * scale
        let line = Path { path in
            path.move(to: CGPoint(x: x, y: rulerHeight - 4))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(line, with: .color(Color.primary.opacity(0.75)), lineWidth: 1.5)
        let knob = Path { path in
            path.move(to: CGPoint(x: x, y: rulerHeight - 4))
            path.addLine(to: CGPoint(x: x - 4, y: rulerHeight - 10))
            path.addLine(to: CGPoint(x: x + 4, y: rulerHeight - 10))
            path.closeSubpath()
        }
        context.fill(knob, with: .color(Color.primary.opacity(0.75)))
    }
}

/// The whole recording in miniature.
private enum TimelineOverview {
    static func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        timeline: SpeakerTimeline,
        durationMs: Int,
        positionMs: Int,
        visible: CGRect
    ) {
        let scale = size.width / CGFloat(max(1, durationMs))
        let lanes = timeline.lanes
        guard !lanes.isEmpty else { return }
        let rowHeight = max(1.5, (size.height - 2) / CGFloat(lanes.count))
        for (index, lane) in lanes.enumerated() {
            let y = 1 + CGFloat(index) * rowHeight
            let color = SpeakerPalette.color(at: index)
            for run in lane.runs {
                let bar = CGRect(
                    x: CGFloat(run.startMs) * scale,
                    y: y,
                    width: max(1, CGFloat(run.durationMs) * scale),
                    height: max(1, rowHeight - 0.8)
                )
                context.fill(Path(bar), with: .color(color))
            }
        }
        // What is off screen is dimmed, so the window onto the recording reads at a glance.
        let outside = Color.primary.opacity(0.35)
        let left = CGRect(x: 0, y: 0, width: max(0, visible.minX), height: size.height)
        let right = CGRect(
            x: min(size.width, visible.maxX),
            y: 0,
            width: max(0, size.width - visible.maxX),
            height: size.height
        )
        context.fill(Path(left), with: .color(outside))
        context.fill(Path(right), with: .color(outside))
        let window = Path(
            roundedRect: visible.intersection(CGRect(origin: .zero, size: size)).insetBy(dx: 0.5, dy: 0.5),
            cornerRadius: 3
        )
        context.stroke(window, with: .color(Color.primary.opacity(0.6)), lineWidth: 1)
        let playhead = CGRect(x: CGFloat(positionMs) * scale - 0.5, y: 0, width: 1.5, height: size.height)
        context.fill(Path(playhead), with: .color(Color.primary.opacity(0.8)))
    }
}

/// How far apart the ruler's marks are, given how wide the recording is drawn.
enum TimelineTicks {
    static let steps = [
        1_000, 2_000, 5_000, 10_000, 15_000, 30_000,
        60_000, 120_000, 300_000, 600_000, 900_000, 1_800_000,
    ]

    static func step(durationMs: Int, width: CGFloat) -> Int {
        let minimumSpacing: CGFloat = 72
        for step in steps where CGFloat(step) / CGFloat(max(1, durationMs)) * width >= minimumSpacing {
            return step
        }
        return steps.last ?? 60_000
    }
}

/// A time as a person reads it, in the length the recording needs.
func timelineClock(_ milliseconds: Int) -> String {
    let total = max(0, milliseconds / 1_000)
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let seconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%d:%02d", minutes, seconds)
}

/// A voice's speaking time, as the number of minutes a reader wants.
func timelineSpoken(_ milliseconds: Int) -> String {
    let seconds = max(0, milliseconds / 1_000)
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(minutes % 60)m"
}
