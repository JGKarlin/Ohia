import AppKit
import SwiftUI
import OhiaML

// The shared building blocks of the guide surfaces — the Deadlines tab's
// guide pane and the Projects workroom's project guide. Both render the same
// grammar (the focused-surface card chrome over a briefing, the WHAT'S NEEDED
// tickable step list with per-document readouts, and the FILES card with the
// working-file drop strip); only the dossier header and the obligation
// affordance differ per host.

/// Display state for one resource's deep-read in a guide surface.
enum DeadlineGuideReadoutState: Equatable {
    case loading
    case loaded(DeadlineResourceReadout)
    case unavailable
}

/// The last time a guide re-distilled because its file set changed, for the
/// FILES footer note.
struct DeadlineGuideLastRead: Equatable {
    let at: Date
    let reason: String
}

/// Scope-specific evidence that can change a generated guide. Project and
/// deadline views intentionally ignore each other's fingerprints and display
/// projection changes, avoiding a loading flash when the guide input did not
/// change.
enum GuideSummaryEvidenceIdentity: Equatable {
    case project(messageSource: String, userAddresses: String, sharedActions: String)
    case deadline(input: String)

    static func project(_ signature: ProjectsSnapshotSignature) -> Self {
        .project(
            messageSource: signature.projectMessageSourceFingerprint,
            userAddresses: signature.userAddressesFingerprint,
            sharedActions: signature.sharedMessageActionFingerprint
        )
    }

    static func deadline(_ signature: ProjectsSnapshotSignature) -> Self {
        .deadline(input: signature.deadlineInputFingerprint)
    }
}

/// Shared identity for automatic project and deadline guide refreshes. Opening
/// a guide always starts its task; relevant evidence and file changes restart
/// it while the summary service reuses unchanged input fingerprints.
struct GuideSummaryTaskKey: Equatable {
    let scopeID: String
    let summaryRequestKey: String
    let evidenceIdentity: GuideSummaryEvidenceIdentity
    let filesRevision: Int
}

/// Resource keys shared by the guide hosts and their readout state maps.
enum GuideResourceKeys {
    /// The document action id `DeadlineSummaryPostProcessor` mints, so a
    /// host's readout keys land on the matching step rows.
    static func document(filename: String) -> String {
        DeadlineActionItem.documentID(filename: filename)
    }

    /// Working files are not steps; their readouts render under the FILES
    /// rows, keyed distinctly so an attachment and a working file with the
    /// same name never collide.
    static func workingFile(filename: String) -> String {
        "workfile:\(filename.lowercased())"
    }
}

/// The focused-surface content-card chrome (`DeadlineFocusedView`'s email
/// card): radius 10, glass panel fill, hairline border, 14pt inset.
struct GuideCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(OhiaColors.glassPanelBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(OhiaColors.glassBorder, lineWidth: 1))
            )
    }
}

/// Standalone section heading shared by the project and deadline focused
/// feeds, including a compact optional progress detail.
struct GuideSectionHeader: View {
    let title: String
    let systemImage: String
    let detail: String?

    init(_ title: String, systemImage: String, detail: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(title)
                .font(OhiaTypography.telemetrySectionCaps)
                .tracking(0.5)
            if let detail {
                Text(detail)
                    .font(OhiaTypography.telemetrySectionCaps)
                    .tracking(0.4)
                    .monospacedDigit()
                    .foregroundStyle(OhiaColors.textTertiary)
            }
        }
        .foregroundStyle(OhiaColors.accentOrange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The briefing paragraph in its three states.
struct GuideBriefingBody: View {
    let summaryState: DeadlineSummaryState
    /// "deadline" or "project" — the loading line's subject.
    let subjectNoun: String
    let placeholderWidth: CGFloat

    @Environment(\.readingTextSize) private var readingTextSize

    var body: some View {
        switch summaryState {
        case .loading:
            VStack(alignment: .leading, spacing: 6) {
                Text("reading the \(subjectNoun)")
                    .font(.system(size: 10.5).italic())
                    .foregroundStyle(OhiaColors.textTertiary)
                SummaryLoadingPlaceholderView(contentWidth: placeholderWidth)
            }
        case .loaded(let result):
            Text(result.paragraph)
                .font(readingTextSize.font(base: 12.5))
                .lineSpacing(readingTextSize.spacing(3))
                .foregroundStyle(OhiaColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .unavailable(let message):
            Text(message)
                .font(readingTextSize.font(base: 11.5).italic())
                .lineSpacing(readingTextSize.spacing(2.5))
                .foregroundStyle(OhiaColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Numbered tickable step rows with their per-document readouts, and an
/// optional footer row (the deadline pane's Reply / Confirm obligation) below
/// a final hairline. Its host supplies the shared standalone section heading.
struct GuideNeedsList<Footer: View>: View {
    let result: DeadlineSummaryResult
    let completedStepIDs: Set<String>
    /// Keyed by resource key ("document:<filename lowercased>").
    let readoutStates: [String: DeadlineGuideReadoutState]
    let onToggleStep: (_ stepID: String, _ completed: Bool) -> Void
    @ViewBuilder let footer: () -> Footer

    init(
        result: DeadlineSummaryResult,
        completedStepIDs: Set<String>,
        readoutStates: [String: DeadlineGuideReadoutState],
        onToggleStep: @escaping (_ stepID: String, _ completed: Bool) -> Void,
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
    ) {
        self.result = result
        self.completedStepIDs = completedStepIDs
        self.readoutStates = readoutStates
        self.onToggleStep = onToggleStep
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(result.actions.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(OhiaColors.glassBorder.opacity(0.6)).frame(height: 1)
                }
                stepRow(item, number: index + 1)
            }
            footer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepRow(_ item: DeadlineActionItem, number: Int) -> some View {
        let done = completedStepIDs.contains(item.id)
        return HStack(alignment: .top, spacing: 10) {
            tickCircle(stepID: item.id, number: number, done: done)
            VStack(alignment: .leading, spacing: 0) {
                DeadlineActionRow(item: item)
                    .opacity(done ? 0.55 : 1)
                if item.kind == .document, let state = readoutStates[item.id] {
                    GuideReadoutBlock(state: state, sourceLabel: (item.value ?? "document").uppercased())
                        .padding(.top, 7)
                        .opacity(done ? 0.55 : 1)
                }
            }
        }
        .padding(.vertical, 11)
    }

    private func tickCircle(stepID: String, number: Int, done: Bool) -> some View {
        Button {
            onToggleStep(stepID, !done)
        } label: {
            ZStack {
                Circle()
                    .fill(done ? OhiaColors.chipActiveBackground : Color.clear)
                Circle()
                    .strokeBorder(OhiaColors.chipActiveBorder.opacity(done ? 1 : 0.6), lineWidth: 1)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(OhiaColors.chipActiveForeground)
                } else {
                    Text("\(number)")
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(OhiaColors.textSecondary)
                }
            }
            .frame(width: 17, height: 17)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .accessibilityLabel(done ? "Mark step \(number) not done" : "Mark step \(number) done")
        .help(done ? "Mark not done" : "Mark done")
    }
}

/// The model's close reading of one document (a step's attachment or a
/// working file). Renders nothing for `.unavailable` (the row alone is the
/// honest state).
struct GuideReadoutBlock: View {
    let state: DeadlineGuideReadoutState
    let sourceLabel: String

    @Environment(\.readingTextSize) private var readingTextSize

    var body: some View {
        if state != .unavailable {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 8, weight: .semibold))
                    Text("READ FROM \(sourceLabel)")
                        .font(.system(size: 8.5, weight: .semibold))
                        .tracking(0.8)
                        .lineLimit(1)
                }
                .foregroundStyle(OhiaColors.textTertiary)
                switch state {
                case .loading:
                    Text("reading the document")
                        .font(.system(size: 10.5).italic())
                        .foregroundStyle(OhiaColors.textTertiary)
                case .loaded(let readout):
                    Text(readout.text)
                        .font(readingTextSize.font(base: 11.5))
                        .lineSpacing(readingTextSize.spacing(2.5))
                        .foregroundStyle(OhiaColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                case .unavailable:
                    EmptyView()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(OhiaColors.iconPillBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(OhiaColors.iconPillBorder, lineWidth: 1)
            )
        }
    }
}

/// The FILES section: thread attachments, the owner's working files (each
/// with its readout when one exists), the drop strip, and the last-re-read
/// note.
struct GuideFilesSection: View {
    let attachments: [DeadlineSummaryAttachment]
    let workFiles: [DeadlineWorkFile]
    /// Keyed by resource key ("workfile:<filename lowercased>").
    let readoutStates: [String: DeadlineGuideReadoutState]
    let lastRead: DeadlineGuideLastRead?
    /// Origin meta for attachment rows — "from the thread" on a deadline,
    /// "from the correspondence" on a project (whose attachments span many
    /// threads).
    let attachmentMeta: String
    /// "Deadline" or "Project" — the removal menu item's object.
    let removalNoun: String
    let onDropFiles: ([URL]) -> Void
    let onRemoveWorkFile: (DeadlineWorkFile) -> Void

    @State private var dropTargeted = false

    var body: some View {
        let fileCount = attachments.count + workFiles.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "paperclip")
                    .font(.system(size: 9, weight: .semibold))
                Text("FILES")
                    .font(OhiaTypography.telemetrySectionCaps)
                    .tracking(0.5)
                if fileCount > 0 {
                    Text("· \(fileCount)")
                        .font(OhiaTypography.telemetrySectionCaps)
                        .monospacedDigit()
                        .foregroundStyle(OhiaColors.textTertiary)
                }
            }
            .foregroundStyle(OhiaColors.ohiaGreen)
            .padding(.bottom, 6)
            ForEach(attachments, id: \.filename) { attachment in
                fileRow(
                    filename: attachment.filename,
                    meta: attachmentMeta,
                    url: attachment.filePath.map { URL(fileURLWithPath: $0) },
                    removal: nil
                )
            }
            ForEach(workFiles) { file in
                VStack(alignment: .leading, spacing: 0) {
                    fileRow(
                        filename: file.filename,
                        meta: "added by you · \(DeadlineFormatting.dayLabel(file.addedAt))",
                        url: file.url,
                        removal: { onRemoveWorkFile(file) }
                    )
                    if let state = readoutStates[GuideResourceKeys.workingFile(filename: file.filename)] {
                        GuideReadoutBlock(state: state, sourceLabel: file.filename.uppercased())
                            .padding(.leading, 22)
                            .padding(.bottom, 7)
                    }
                }
            }
            dropZone
                .padding(.top, 8)
            if let lastRead {
                Text("guide re-read \(DeadlineFormatting.dayTimeLabel(lastRead.at)), after \(lastRead.reason)")
                    .font(.system(size: 10).italic())
                    .foregroundStyle(OhiaColors.textTertiary)
                    .padding(.top, 9)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileRow(
        filename: String,
        meta: String,
        url: URL?,
        removal: (() -> Void)?
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                if let url { NSWorkspace.shared.open(url) }
            } label: {
                Label(filename, systemImage: "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(url == nil ? OhiaColors.textSecondary : OhiaColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
            .help(url == nil ? "Attached file" : "Open the file")
            Spacer(minLength: 8)
            Text(meta)
                .font(.system(size: 9.5))
                .foregroundStyle(OhiaColors.textTertiary)
        }
        .padding(.vertical, 5)
        .contextMenu {
            if let url {
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            if let removal {
                Button(
                    "Remove from This \(removalNoun)",
                    systemImage: "trash",
                    role: .destructive,
                    action: removal
                )
            }
        }
    }

    private var dropZone: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
            Text("Drop a working file here — the guide re-reads when files change")
                .font(.system(size: 10.5))
        }
        .foregroundStyle(dropTargeted ? OhiaColors.chipActiveForeground : OhiaColors.textTertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(dropTargeted ? OhiaColors.chipActiveBackground : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    dropTargeted ? OhiaColors.chipActiveBorder : OhiaColors.glassBorderBright,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard fileURLs.isEmpty == false else { return false }
            onDropFiles(fileURLs)
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
    }
}
