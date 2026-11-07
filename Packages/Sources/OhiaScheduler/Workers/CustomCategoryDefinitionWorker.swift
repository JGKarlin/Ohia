import Foundation
import SwiftData
import OSLog
import OhiaCore
import OhiaML

private let customCategoryLogger = Logger(
    subsystem: "org.jgkarlin.Ohia",
    category: "customCategories"
)

/// Drains `.customCategoryDefinition` jobs: finds every collecting
/// `CustomMailCategory` whose tagged-example count reached the activation
/// threshold, asks the local engine to write its classifier definition
/// (category name + tagged example evidence + the fixed-category definition
/// style as the format reference), persists the definition, and flips the
/// category to `.active`.
///
/// Idempotent by construction: it re-derives its worklist from the store on
/// every run, so a crash mid-batch, a duplicate job, or a stale enqueue all
/// converge to the same end state. Failures throw so the `JobQueue` retry /
/// backoff machinery owns rescheduling; `BackgroundScheduler.
/// ensurePipelineJobsExist` reseeds the job whenever threshold-reaching
/// collecting categories remain.
public struct CustomCategoryDefinitionWorker {

    public struct Outcome: Sendable {
        public let categoriesVisited: Int
        public let categoriesActivated: Int
    }

    private let engine: any TrainingEngine

    public init(engine: any TrainingEngine) {
        self.engine = engine
    }

    @MainActor
    public func run(context: ModelContext) async throws -> Outcome {
        let allCategories = try context.fetch(FetchDescriptor<CustomMailCategory>())
        let ready = allCategories
            .filter {
                $0.status == .collecting
                    && CustomMailCategoryCatalog.isEligibleForActivation($0, context: context)
            }
            .sorted { $0.createdAt < $1.createdAt }
        guard ready.isEmpty == false else {
            return Outcome(categoriesVisited: 0, categoriesActivated: 0)
        }

        let generator = CustomCategoryDefinitionGenerator(engine: engine)
        var activated = 0
        var firstError: Error?

        for category in ready {
            let others = allCategories
                .filter { $0.key != category.key && $0.status == .active }
                .map { CustomMailCategoryDescriptor($0, hasSenderDiversity: true) }
            let examples = Self.examples(for: category, context: context)
            guard examples.isEmpty == false else {
                // Every tagged example message has since been deleted; the
                // category cannot activate until the user tags live
                // messages again. Not an error — just skip.
                customCategoryLogger.warning(
                    "Custom category \(category.key, privacy: .public) reached threshold but has no resolvable example messages; staying in collecting"
                )
                continue
            }
            let request = CustomCategoryDefinitionRequest(
                displayName: category.displayName,
                key: category.key,
                examples: examples,
                otherCustomCategories: others
            )
            do {
                let definition = try await generator.generateDefinition(for: request)
                category.definition = definition
                category.status = .active
                category.activatedAt = Date()
                try context.save()
                activated += 1
                customCategoryLogger.info(
                    "Activated custom category \(category.key, privacy: .public) with \(examples.count, privacy: .public) examples"
                )
                NotificationCenter.default.post(name: .ohiaCustomCategoriesDidChange, object: nil)
            } catch {
                customCategoryLogger.error(
                    "Definition generation failed for \(category.key, privacy: .public): \(String(reflecting: type(of: error)), privacy: .public)"
                )
                if firstError == nil { firstError = error }
            }
        }

        // Surface the failure to the job queue (retry with backoff) only
        // when nothing activated this run; partial progress completes the
        // job and the scheduler reseeds for the remainder.
        if activated == 0, let firstError {
            throw firstError
        }
        return Outcome(categoriesVisited: ready.count, categoriesActivated: activated)
    }

    /// Whether any collecting category is waiting on definition
    /// generation. Used by `BackgroundScheduler.ensurePipelineJobsExist`
    /// to reseed the job after restarts or transient failures.
    @MainActor
    public static func hasPendingWork(context: ModelContext) -> Bool {
        let rows = (try? context.fetch(FetchDescriptor<CustomMailCategory>())) ?? []
        return rows.contains {
            $0.status == .collecting
                && CustomMailCategoryCatalog.isEligibleForActivation($0, context: context)
        }
    }

    /// Resolves the tagged example messages into prompt evidence: subject,
    /// sender line, and the best available content excerpt (generated body
    /// summary when present, otherwise a body-text prefix).
    @MainActor
    static func examples(
        for category: CustomMailCategory,
        context: ModelContext
    ) -> [CustomCategoryDefinitionRequest.Example] {
        category.exampleMessageIDs.compactMap { messageID in
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.id == messageID }
            )
            descriptor.fetchLimit = 1
            guard let message = try? context.fetch(descriptor).first else { return nil }

            let subject = MIMEHeaderDecoder.decodeEncodedWords(message.subject)
            let senderName = message.fromName.map(MIMEHeaderDecoder.decodeEncodedWords) ?? ""
            let senderLine: String
            if senderName.isEmpty {
                senderLine = message.fromAddress
            } else if message.fromAddress.isEmpty {
                senderLine = senderName
            } else {
                senderLine = "\(senderName) <\(message.fromAddress)>"
            }

            let excerpt: String
            if let summary = message.analysis?.bodySummary?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               summary.isEmpty == false {
                excerpt = summary
            } else if let path = message.bodyTextPath,
                      let body = Self.bodyPrefix(atPath: path) {
                excerpt = body
            } else {
                excerpt = ""
            }
            return CustomCategoryDefinitionRequest.Example(
                subject: subject,
                senderLine: senderLine,
                excerpt: excerpt
            )
        }
    }

    private static func bodyPrefix(atPath path: String, byteLimit: Int = 4_096) -> String? {
        guard path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteLimit), data.isEmpty == false else {
            return nil
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
