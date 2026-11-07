import Foundation
import SwiftData
import OhiaCore
import OhiaML

@MainActor
enum MeetingCalendarEntryLoader {
    static func load(
        modelContext: ModelContext,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) async throws -> [MeetingEntry] {
        try? modelContext.save()
        let container = modelContext.container
        let gatherTask = Task.detached(priority: .utility) {
            try loadDetached(container: container, now: now, calendar: calendar)
        }
        return try await withTaskCancellationHandler {
            let entries = try await gatherTask.value
            try Task.checkCancellation()
            return entries
        } onCancel: {
            gatherTask.cancel()
        }
    }

    private nonisolated static func loadDetached(
        container: ModelContainer,
        now: Date,
        calendar: Calendar
    ) throws -> [MeetingEntry] {
        let modelContext = ModelContext(container)
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { message in
                message.isSentByUser == false
            }
        )
        let messages = try modelContext.fetch(descriptor)
        let decoder = JSONDecoder()
        var observations: [MeetingObservation] = []

        for message in messages {
            try Task.checkCancellation()
            let messageDate = message.receivedAt ?? message.sentAt ?? message.ingestedAt
            let bodyCandidate: MeetingCandidate? = {
                guard message.isLiveInboundTriageEligible,
                      let json = message.analysis?.dimensionsJSON,
                      let data = json.data(using: .utf8),
                      let dimensions = try? decoder.decode(MessageDimensions.self, from: data) else {
                    return nil
                }
                return dimensions.meetings?.first
            }()
            let invitations = message.attachments.flatMap { attachment -> [CalendarInvitation] in
                let isCalendar = attachment.mimeType
                    .lowercased()
                    .hasPrefix("text/calendar")
                    || attachment.filename.lowercased().hasSuffix(".ics")
                guard isCalendar,
                      let path = attachment.filePath,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                    return []
                }
                return CalendarInvitationParser.parse(
                    data,
                    defaultTimeZone: calendar.timeZone
                )
            }
            guard bodyCandidate != nil || invitations.isEmpty == false else { continue }
            observations.append(
                MeetingObservation(
                    messageID: message.id,
                    threadID: message.thread?.id.uuidString,
                    messageDate: messageDate,
                    subject: MIMEHeaderDecoder.decodeEncodedWords(message.subject),
                    bodyCandidate: bodyCandidate,
                    invitations: invitations
                )
            )
        }

        // Avoid creating stale historical calendar clutter when the opt-in is
        // first enabled. Future cancellations remain because their VEVENT end
        // date is still in the active window.
        let cutoff = calendar.date(byAdding: .day, value: -1, to: now)
            ?? now.addingTimeInterval(-86_400)
        return MeetingTracker.build(observations: observations, calendar: calendar)
            .filter { $0.endDate >= cutoff }
    }
}
