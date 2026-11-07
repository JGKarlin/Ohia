import Foundation

public struct SMTPResponse: Sendable, Equatable {
    public let code: Int
    public let lines: [String]

    public var isPositiveCompletion: Bool { code >= 200 && code < 300 }
    public var isPositiveIntermediate: Bool { code >= 300 && code < 400 }
    public var isTransientNegative: Bool { code >= 400 && code < 500 }
    public var isPermanentNegative: Bool { code >= 500 && code < 600 }

    public enum ParseError: Swift.Error { case empty, malformed(String), inconsistentCode }

    public init(code: Int, lines: [String]) { self.code = code; self.lines = lines }

    public static func parse(_ raw: String) throws -> SMTPResponse {
        let rawLines = raw.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard !rawLines.isEmpty else { throw ParseError.empty }
        var firstCode: Int?
        var collected: [String] = []
        for line in rawLines {
            guard line.count >= 4 else { throw ParseError.malformed(line) }
            let codeStr = String(line.prefix(3))
            let sep = line[line.index(line.startIndex, offsetBy: 3)]
            guard let code = Int(codeStr), sep == " " || sep == "-" else {
                throw ParseError.malformed(line)
            }
            if firstCode == nil { firstCode = code }
            else if firstCode != code { throw ParseError.inconsistentCode }
            collected.append(String(line.dropFirst(4)))
        }
        return SMTPResponse(code: firstCode ?? 0, lines: collected)
    }
}
