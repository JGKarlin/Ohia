import AppKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct WithheldRowDragPayload: Codable, Equatable, Hashable, Transferable {
    let rowIDs: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ohiaWithheldRows)
    }

    var itemProvider: NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.ohiaWithheldRows.identifier,
            visibility: .ownProcess
        ) { completion in
            do {
                completion(try JSONEncoder().encode(self), nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
        return provider
    }

    static var pasteboardType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(UTType.ohiaWithheldRows.identifier)
    }

    static func hasPayload(_ pasteboard: NSPasteboard) -> Bool {
        let boardHasPayload = pasteboard.availableType(from: [pasteboardType]) != nil
        let itemHasPayload = pasteboard.pasteboardItems?.contains { item in
            item.types.contains(pasteboardType)
        } ?? false
        return boardHasPayload || itemHasPayload
    }

    static func payloads(from pasteboard: NSPasteboard) -> [WithheldRowDragPayload] {
        let decoder = JSONDecoder()
        var payloads: [WithheldRowDragPayload] = []

        if let data = pasteboard.data(forType: pasteboardType),
           let payload = try? decoder.decode(WithheldRowDragPayload.self, from: data) {
            payloads.append(payload)
        }

        for item in pasteboard.pasteboardItems ?? [] {
            guard let data = item.data(forType: pasteboardType),
                  let payload = try? decoder.decode(WithheldRowDragPayload.self, from: data),
                  !payloads.contains(payload) else {
                continue
            }
            payloads.append(payload)
        }

        return payloads
    }
}

extension UTType {
    static let ohiaWithheldRows = UTType(exportedAs: "com.ohia.withheld-rows")
}
