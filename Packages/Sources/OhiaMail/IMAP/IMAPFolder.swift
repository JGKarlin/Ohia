import Foundation

public struct IMAPFolder: Sendable, Equatable {
    public let name: String
    public let delimiter: Character?
    public let attributes: Set<String>          // \Noselect, \HasChildren, \All, \Sent, \Inbox, etc.

    public init(name: String, delimiter: Character?, attributes: Set<String>) {
        self.name = name
        self.delimiter = delimiter
        self.attributes = attributes
    }

    public var isNoselect: Bool { attributes.contains("\\Noselect") }
    public var isAll: Bool      { attributes.contains("\\All") }
    public var isSent: Bool     { attributes.contains("\\Sent") }
    public var isTrash: Bool    { attributes.contains("\\Trash") }
    public var isJunk: Bool     { attributes.contains("\\Junk") }
    public var isDrafts: Bool   { attributes.contains("\\Drafts") }
    public var isArchive: Bool  { attributes.contains("\\Archive") }
}
