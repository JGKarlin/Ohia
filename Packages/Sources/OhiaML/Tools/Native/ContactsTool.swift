import Foundation
import Contacts

public final class ContactsTool: AgentTool, @unchecked Sendable {
    public let name = "contacts"
    public let toolDescription = "Look up contact details — organization, phone, email, address"

    private let store = CNContactStore()

    public init() {}

    public func execute(query: String, context: ToolContext) throws -> ToolResult {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else {
            return ToolResult(findings: [Finding(
                text: "Contacts access not granted — enable in System Settings > Privacy & Security > Contacts",
                confidence: 0.0
            )])
        }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]

        let contacts: [CNContact]
        do {
            let predicate = CNContact.predicateForContacts(matchingName: query)
            contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
        } catch {
            return ToolResult(findings: [Finding(text: "Contact search failed: \(error.localizedDescription)", confidence: 0.0)])
        }

        if contacts.isEmpty {
            return ToolResult(findings: [Finding(text: "No contacts found matching '\(query)'", confidence: 0.5)])
        }

        let findings = contacts.map { contact -> Finding in
            var parts: [String] = []
            let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { parts.append("Name: \(name)") }
            if !contact.organizationName.isEmpty { parts.append("Organization: \(contact.organizationName)") }
            for email in contact.emailAddresses { parts.append("Email: \(email.value)") }
            for phone in contact.phoneNumbers { parts.append("Phone: \(phone.value.stringValue)") }
            return Finding(text: parts.joined(separator: "\n"), confidence: 0.95)
        }
        return ToolResult(findings: findings)
    }
}
