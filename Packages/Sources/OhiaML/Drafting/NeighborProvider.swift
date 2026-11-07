// Packages/Sources/OhiaML/Drafting/NeighborProvider.swift
import Foundation
import OhiaCore

public protocol NeighborProviding: Sendable {
    func fetchNeighbors(
        citations: [Citation],
        findings: [Finding],
        correspondentEmail: String,
        subject: String
    ) -> FocusNeighborSet
}
