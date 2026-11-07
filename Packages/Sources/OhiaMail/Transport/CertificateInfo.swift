// Packages/Sources/OhiaMail/Transport/CertificateInfo.swift
import Foundation

/// Parsed leaf certificate presented by a peer, surfaced to the Verify
/// Certificate sheet. `sha256Fingerprint` is the value stored as an
/// `Account.pinnedCertSHA256` when the user trusts the cert.
public struct CertificateInfo: Sendable, Equatable, Identifiable {
    public let subjectCN: String          // e.g. "mail.example.com"
    public let issuerCN: String           // same as subjectCN iff self-signed
    public let isSelfSigned: Bool         // full subject DN == full issuer DN
    public let notBefore: Date
    public let notAfter: Date
    public let sha256Fingerprint: String  // 64 hex chars, lowercase, no colons
    public let sha1Fingerprint: String    // 40 hex chars, displayed only
    public let fullSubject: String        // RFC 2253 subject DN
    public let fullIssuer: String         // RFC 2253 issuer DN
    public let subjectAltNames: [String]  // ["DNS:mail.example.com", "IP:10.0.0.1", ...]

    // Identifiable conformance drives SwiftUI's .sheet(item:) presentation.
    public var id: String { sha256Fingerprint }

    public init(
        subjectCN: String,
        issuerCN: String,
        isSelfSigned: Bool,
        notBefore: Date,
        notAfter: Date,
        sha256Fingerprint: String,
        sha1Fingerprint: String,
        fullSubject: String,
        fullIssuer: String,
        subjectAltNames: [String]
    ) {
        self.subjectCN = subjectCN
        self.issuerCN = issuerCN
        self.isSelfSigned = isSelfSigned
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.sha256Fingerprint = sha256Fingerprint
        self.sha1Fingerprint = sha1Fingerprint
        self.fullSubject = fullSubject
        self.fullIssuer = fullIssuer
        self.subjectAltNames = subjectAltNames
    }
}
