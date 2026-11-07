import Foundation
import OhiaCore
import SwiftData

@MainActor
public enum SemanticTagIntake {
    public static let maintenancePriority = 6

    public static func persist(
        candidates: [SemanticTagCandidate],
        for message: Message,
        extractionVersion: String,
        context: ModelContext,
        at date: Date = .now
    ) throws {
        let boundedCandidates = Array(candidates.prefix(3))
        let repository = SemanticTagRepository(context: context)
        let messageID = message.id
        let existingObservations = try context.fetch(
            FetchDescriptor(
                predicate: #Predicate<SemanticTagObservation> { $0.messageID == messageID }
            )
        )
        let jobs = try context.fetch(FetchDescriptor(
            predicate: #Predicate<Job> { $0.messageId == messageID }
        ))
        var retainedObservationIDs = Set<UUID>()
        var desiredTagIDs = Set<UUID>()

        for candidate in boundedCandidates {
            let observation = try repository.persistObservation(
                message: message,
                candidate: candidate,
                extractionVersion: extractionVersion,
                at: date
            )
            retainedObservationIDs.insert(observation.id)

            let exactMatches = try repository.exactTags(matching: candidate)
            if var tag = exactMatches.first {
                for duplicate in exactMatches.dropFirst() {
                    tag = try repository.merge(tag, with: duplicate, at: date)
                }
                try repository.attachAliases(from: candidate, to: tag, at: date)
                _ = try repository.upsertMembership(
                    message: message,
                    tag: tag,
                    candidate: candidate,
                    observation: observation,
                    evidenceJSON: "{}",
                    at: date
                )
                _ = try repository.promoteIfEligible(tag, at: date)
                desiredTagIDs.insert(tag.id)
            } else {
                observation.state = .pending
                observation.resolvedTagID = nil
                observation.resolvedAt = nil
                observation.invalidReason = nil
                stageResolutionJob(
                    observation: observation,
                    messageID: message.id,
                    existingJobs: jobs,
                    context: context,
                    at: date
                )
            }
        }

        for observation in existingObservations
            where !retainedObservationIDs.contains(observation.id) {
            let payload = observation.id.uuidString
            for job in jobs where job.type == .resolveSemanticTags && job.payload == payload {
                context.delete(job)
            }
            context.delete(observation)
        }

        let memberships = try context.fetch(
            FetchDescriptor(
                predicate: #Predicate<MessageSemanticTagMembership> { $0.messageID == messageID }
            )
        )
        for membership in memberships where !desiredTagIDs.contains(membership.tagID) {
            context.delete(membership)
        }

        try ensureDimensions(for: message)
        try repository.rewriteProjection(for: message)
    }

    private static func stageResolutionJob(
        observation: SemanticTagObservation,
        messageID: UUID,
        existingJobs: [Job],
        context: ModelContext,
        at date: Date
    ) {
        let payload = observation.id.uuidString
        guard !existingJobs.contains(where: {
            $0.type == .resolveSemanticTags
                && $0.payload == payload
                && ($0.status == .pending || $0.status == .running)
        }) else {
            return
        }
        let job = Job(type: .resolveSemanticTags, priority: maintenancePriority)
        job.messageId = messageID
        job.payload = payload
        job.createdAt = date
        context.insert(job)
    }

    private static func ensureDimensions(for message: Message) throws {
        guard let analysis = message.analysis else {
            throw SemanticTagRepositoryError.missingAnalysis
        }
        if let data = analysis.dimensionsJSON.data(using: .utf8),
           (try? JSONDecoder().decode(MessageDimensions.self, from: data)) != nil {
            return
        }
        let dimensions = MessageDimensions(extractionVersion: "semantic-tags-v1")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        analysis.dimensionsJSON = String(
            decoding: try encoder.encode(dimensions),
            as: UTF8.self
        )
    }
}
