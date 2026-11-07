// Ohia/Settings/Signatures/MeCardReader.swift
// Prefills the signature studio's contact form from the user's macOS
// Contacts "me card" (My Card in Contacts.app). Fallback prefill comes
// from the account's primary identity; Contacts access is never required.

import Contacts
import Foundation
import OhiaCore

enum MeCardReader {

    enum Availability: Equatable {
        case available
        case noMeCard
        case accessDenied
        case accessNotDetermined
    }

    struct Result {
        var fields: SignatureContactFields
        var availability: Availability
    }

    static var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    /// True for statuses that permit a fetch. Anything that is not an
    /// explicit denial is treated as fetchable — the read itself degrades
    /// gracefully to the identity fallback when the card is unreachable.
    static var isAuthorized: Bool {
        authorizationStatus == .authorized
    }

    static func requestAccess() async -> Bool {
        let store = CNContactStore()
        return (try? await store.requestAccess(for: .contacts)) ?? false
    }

    /// Reads the me card into contact-form fields, merging the identity
    /// fallback for anything the card lacks. Blocking Contacts I/O — call
    /// off the main actor.
    ///
    /// `accountEmail` is not a fallback: a signature signs one account's
    /// mail, so that account's own address is the one to recommend. The me
    /// card's first email is whatever Contacts happens to list first — for
    /// most people a personal address — and signing a work account with it
    /// is simply wrong. The card's email is used only when the account has
    /// no address to offer.
    nonisolated static func read(
        fallbackName: String?,
        accountEmail: String?
    ) -> Result {
        let fallback = SignatureContactFields(values: [
            (.name, fallbackName),
            (.email, accountEmail)
        ])
        switch authorizationStatus {
        case .notDetermined:
            return Result(fields: fallback, availability: .accessNotDetermined)
        case .denied, .restricted:
            return Result(fields: fallback, availability: .accessDenied)
        default:
            break
        }

        // No note key — reading notes requires the Apple-granted
        // com.apple.developer.contacts.notes entitlement.
        let keys: [any CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactJobTitleKey as any CNKeyDescriptor,
            CNContactOrganizationNameKey as any CNKeyDescriptor,
            CNContactDepartmentNameKey as any CNKeyDescriptor,
            CNContactPhoneNumbersKey as any CNKeyDescriptor,
            CNContactEmailAddressesKey as any CNKeyDescriptor,
            CNContactUrlAddressesKey as any CNKeyDescriptor,
            CNContactPostalAddressesKey as any CNKeyDescriptor,
            CNContactSocialProfilesKey as any CNKeyDescriptor
        ]

        let store = CNContactStore()
        guard let card = try? store.unifiedMeContactWithKeys(toFetch: keys) else {
            return Result(fields: fallback, availability: .noMeCard)
        }

        // CNContactFormatter orders name components per the card's script
        // and the user's locale (family-name-first where that is correct)
        // — never hand-join given/family.
        let fullName = CNContactFormatter.string(from: card, style: .fullName)?
            .trimmingCharacters(in: .whitespaces) ?? ""

        let postal = card.postalAddresses.first.map { labeled -> String in
            let address = labeled.value
            let parts = [
                address.street,
                address.city,
                address.state,
                address.postalCode,
                address.country
            ].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return parts.joined(separator: ", ")
        }

        let phones = phoneRows(from: card)
        var values: [(SignatureFieldKind, String?)] = [
            (.name, fullName.isEmpty ? fallback.value(for: .name) : fullName),
            (.title, card.jobTitle.isEmpty ? nil : card.jobTitle),
            (.organization, card.organizationName.isEmpty ? nil : card.organizationName),
            (.department, card.departmentName.isEmpty ? nil : card.departmentName),
            (.phone, phones[.phone]),
            (.mobile, phones[.mobile]),
            (.office, phones[.office]),
            (.fax, phones[.fax]),
            (.email, accountEmail ?? card.emailAddresses.first.map { String($0.value) }),
            (.website, card.urlAddresses.first.map { String($0.value) }),
            (.postalAddress, postal)
        ]
        values.append(contentsOf: socialRows(from: card))

        return Result(fields: SignatureContactFields(values: values), availability: .available)
    }

    /// Splits the card's phone numbers across the labeled rows Contacts
    /// already distinguishes, instead of collapsing four numbers into one
    /// comma-jammed Phone row. Numbers sharing a row stay comma-separated —
    /// the form and the privacy scrub both read that shape.
    private nonisolated static func phoneRows(
        from card: CNContact
    ) -> [SignatureFieldKind: String] {
        var buckets: [SignatureFieldKind: [String]] = [:]
        for entry in card.phoneNumbers {
            let number = entry.value.stringValue.trimmingCharacters(in: .whitespaces)
            guard !number.isEmpty else { continue }
            let kind: SignatureFieldKind = switch entry.label {
            case CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone: .mobile
            case CNLabelWork, CNLabelPhoneNumberMain:                .office
            case CNLabelPhoneNumberWorkFax, CNLabelPhoneNumberHomeFax,
                 CNLabelPhoneNumberOtherFax:                         .fax
            default:                                                 .phone
            }
            buckets[kind, default: []].append(number)
        }
        return buckets.mapValues { $0.joined(separator: ", ") }
    }

    /// Social profiles the me card already carries, for the services this
    /// app has a label for. An unrecognized service is skipped rather than
    /// guessed at — never infer an account.
    private nonisolated static func socialRows(
        from card: CNContact
    ) -> [(SignatureFieldKind, String?)] {
        card.socialProfiles.compactMap { entry -> (SignatureFieldKind, String?)? in
            let profile = entry.value
            let kind: SignatureFieldKind
            switch profile.service {
            case CNSocialProfileServiceTwitter:  kind = .x
            case CNSocialProfileServiceFacebook: kind = .facebook
            case CNSocialProfileServiceLinkedIn: kind = .linkedIn
            default: return nil
            }
            let handle = profile.username.trimmingCharacters(in: .whitespaces)
            let value = handle.isEmpty
                ? profile.urlString.trimmingCharacters(in: .whitespaces)
                : handle
            return value.isEmpty ? nil : (kind, value)
        }
    }
}
