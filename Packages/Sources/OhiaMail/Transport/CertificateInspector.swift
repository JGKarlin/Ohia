// Packages/Sources/OhiaMail/Transport/CertificateInspector.swift
import Foundation
import Security
import CryptoKit

/// Extracts the fields surfaced to the Verify Certificate sheet from a
/// `SecCertificate`. Pure helper — no network I/O.
enum CertificateInspector {
    static func make(from cert: SecCertificate) -> CertificateInfo {
        let der = SecCertificateCopyData(cert) as Data

        let sha256 = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let sha1   = Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()

        var subjectCN = ""
        if let cn = copyCommonName(cert) {
            subjectCN = cn
        }

        let values = copyCertificateValues(cert)
        let fullSubject = formatDN(values[kSecOIDX509V1SubjectName as String])
        let fullIssuer  = formatDN(values[kSecOIDX509V1IssuerName  as String])

        let issuerCN = extractCommonName(
            from: values[kSecOIDX509V1IssuerName as String]
        ) ?? ""

        let notBefore = extractDate(from: values[kSecOIDX509V1ValidityNotBefore as String]) ?? .distantPast
        let notAfter  = extractDate(from: values[kSecOIDX509V1ValidityNotAfter  as String]) ?? .distantFuture

        let isSelfSigned = (fullSubject == fullIssuer) && !fullSubject.isEmpty

        let sans = extractSANs(
            from: values[kSecOIDSubjectAltName as String]
        )

        return CertificateInfo(
            subjectCN: subjectCN,
            issuerCN: issuerCN,
            isSelfSigned: isSelfSigned,
            notBefore: notBefore,
            notAfter: notAfter,
            sha256Fingerprint: sha256,
            sha1Fingerprint: sha1,
            fullSubject: fullSubject,
            fullIssuer: fullIssuer,
            subjectAltNames: sans
        )
    }

    private static func copyCommonName(_ cert: SecCertificate) -> String? {
        var cn: CFString?
        guard SecCertificateCopyCommonName(cert, &cn) == errSecSuccess,
              let cn = cn else { return nil }
        return cn as String
    }

    private static func copyCertificateValues(_ cert: SecCertificate) -> [String: Any] {
        guard let dict = SecCertificateCopyValues(cert, nil, nil) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private static func formatDN(_ entry: Any?) -> String {
        guard let dict = entry as? [String: Any],
              let components = dict[kSecPropertyKeyValue as String] as? [[String: Any]] else {
            return ""
        }
        var parts: [String] = []
        for component in components {
            guard let labelOID = component[kSecPropertyKeyLabel as String] as? String,
                  let value = component[kSecPropertyKeyValue as String] as? String else { continue }
            parts.append("\(shortName(forOID: labelOID))=\(value)")
        }
        return parts.joined(separator: ", ")
    }

    private static func extractCommonName(from entry: Any?) -> String? {
        guard let dict = entry as? [String: Any],
              let components = dict[kSecPropertyKeyValue as String] as? [[String: Any]] else {
            return nil
        }
        for component in components {
            guard let labelOID = component[kSecPropertyKeyLabel as String] as? String,
                  labelOID == (kSecOIDCommonName as String),
                  let value = component[kSecPropertyKeyValue as String] as? String else { continue }
            return value
        }
        return nil
    }

    private static let oidShortNames: [String: String] = {
        [
            kSecOIDCommonName             as String: "CN",
            kSecOIDOrganizationName       as String: "O",
            kSecOIDOrganizationalUnitName as String: "OU",
            kSecOIDCountryName            as String: "C",
            kSecOIDStateProvinceName      as String: "ST",
            kSecOIDLocalityName           as String: "L",
            kSecOIDEmailAddress           as String: "emailAddress",
        ]
    }()

    private static func shortName(forOID oid: String) -> String {
        oidShortNames[oid] ?? oid
    }

    private static func extractDate(from entry: Any?) -> Date? {
        guard let dict = entry as? [String: Any] else { return nil }
        if let d = dict[kSecPropertyKeyValue as String] as? Date {
            return d
        }
        if let n = dict[kSecPropertyKeyValue as String] as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: n.doubleValue)
        }
        return nil
    }

    private static func extractSANs(from entry: Any?) -> [String] {
        guard let dict = entry as? [String: Any],
              let components = dict[kSecPropertyKeyValue as String] as? [[String: Any]] else {
            return []
        }
        var sans: [String] = []
        for component in components {
            guard let label = component[kSecPropertyKeyLabel as String] as? String,
                  let value = component[kSecPropertyKeyValue as String] as? String else { continue }
            let prefix: String
            switch label {
            case "DNS Name":      prefix = "DNS"
            case "IP Address":    prefix = "IP"
            case "Email Address": prefix = "email"
            case "URI":           prefix = "URI"
            default:              prefix = label
            }
            sans.append("\(prefix):\(value)")
        }
        return sans
    }
}
