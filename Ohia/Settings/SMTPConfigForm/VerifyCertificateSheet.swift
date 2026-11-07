// Ohia/Settings/SMTPConfigForm/VerifyCertificateSheet.swift
import SwiftUI
import OhiaMail

struct VerifyCertificateSheet: View {
    let info: CertificateInfo
    let hasExistingPin: Bool
    let onTrust: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            summaryBlock

            fingerprintsBlock

            DisclosureGroup("Show full details") {
                detailsBlock
            }

            Text("Trusting pins this exact certificate for this account. If the certificate changes later, sending will fail until you re-verify here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Trust", action: onTrust)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.emblem)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 500)
    }

    @ViewBuilder
    private var header: some View {
        switch (info.isSelfSigned, hasExistingPin) {
        case (_, true):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("This certificate does not match the one pinned for this account. This could be a certificate rotation or a man-in-the-middle attack.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.body.weight(.medium))
        case (true, false):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Self-signed certificate")
            }
            .font(.body.weight(.medium))
        case (false, false):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Signed by \(info.issuerCN) (not trusted by macOS)")
            }
            .font(.body.weight(.medium))
        }
    }

    @ViewBuilder
    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Subject", info.subjectCN)
            row("Issuer",  info.issuerCN)
            row("Valid",   "\(Self.dateFormatter.string(from: info.notBefore))  →  \(Self.dateFormatter.string(from: info.notAfter))")
        }
    }

    @ViewBuilder
    private var fingerprintsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            fingerprintRow(label: "SHA-256", hex: info.sha256Fingerprint, bytesPerRow: 16)
            fingerprintRow(label: "SHA-1",   hex: info.sha1Fingerprint,   bytesPerRow: 16)
        }
    }

    @ViewBuilder
    private var detailsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Full Subject", info.fullSubject)
            row("Full Issuer",  info.fullIssuer)
            if !info.subjectAltNames.isEmpty {
                row("Subject Alt Names", info.subjectAltNames.joined(separator: "\n"))
            }
        }
        .padding(.top, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fingerprintRow(label: String, hex: String, bytesPerRow: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(Self.formatHex(hex, bytesPerRow: bytesPerRow))
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    /// "aabbccdd…" → "aa:bb:cc:dd…" grouped in `bytesPerRow`-byte lines.
    static func formatHex(_ hex: String, bytesPerRow: Int) -> String {
        let chars = Array(hex)
        var bytes: [String] = []
        var i = 0
        while i + 2 <= chars.count {
            bytes.append(String(chars[i..<(i + 2)]))
            i += 2
        }
        var rows: [String] = []
        for start in stride(from: 0, to: bytes.count, by: bytesPerRow) {
            let end = min(start + bytesPerRow, bytes.count)
            rows.append(bytes[start..<end].joined(separator: ":"))
        }
        return rows.joined(separator: "\n")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
