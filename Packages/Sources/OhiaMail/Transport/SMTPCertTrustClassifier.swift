// Packages/Sources/OhiaMail/Transport/SMTPCertTrustClassifier.swift
import Foundation

/// Interprets an `SMTPError` (or success) from a Test-Connection run and decides
/// whether the UI should trigger the Verify Certificate flow (i.e. call
/// `MailLineStream.inspectPeerCertificate` and display the sheet).
public enum SMTPCertTrustClassifier {
    public enum Outcome: Equatable {
        case certUntrusted      // cert-chain failure or pin mismatch — show sheet
        case regularFailure     // surface the existing .failure(...) UI
        case success            // connection OK
    }

    public static func classify(_ result: Result<Void, Error>) -> Outcome {
        switch result {
        case .success:
            return .success
        case .failure(let err):
            guard let smtp = err as? SMTPError else { return .regularFailure }
            if case .transportFailed(let msg) = smtp {
                if msg.hasPrefix("TLS handshake failed:") {
                    return .certUntrusted
                }
                if msg.hasPrefix("certificate pin mismatch:") {
                    return .certUntrusted
                }
            }
            return .regularFailure
        }
    }
}
