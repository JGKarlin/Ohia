// StyleTypes.swift
// Sendable value types shared by style discovery: the clusterer (pure
// six-axis clustering), the namer, the describer, and the resolver.

import Foundation
import OhiaCore

/// Sendable snapshot of a `StyleRegister` carried into drafting and the
/// Composer UI. `axes` are the writer's presentation defaults; the name and
/// summary are display text and never enter a prompt.
public struct StyleRegisterNote: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let summary: String
    public let axes: StyleAxisValues?
    public let revision: Int?

    public init(
        id: UUID,
        name: String,
        summary: String,
        axes: StyleAxisValues? = nil,
        revision: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.axes = axes
        self.revision = revision
    }
}

/// One measured sent email in style discovery: its six axes and the
/// correspondent it was written to.
public struct StylePoint: Sendable, Equatable {
    /// Training-pair id, the stable key for deterministic clustering.
    public let id: UUID
    public let axes: StyleAxisValues
    public let correspondentAddress: String?
    public let sampleText: String

    public init(id: UUID, axes: StyleAxisValues, correspondentAddress: String?, sampleText: String) {
        self.id = id
        self.axes = axes
        self.correspondentAddress = correspondentAddress
        self.sampleText = sampleText
    }
}

/// One discovered style in one language: its member emails and centroid.
public struct StyleCluster: Sendable, Equatable {
    public let centroid: StyleAxisValues
    public let memberIDs: [UUID]

    public init(centroid: StyleAxisValues, memberIDs: [UUID]) {
        self.centroid = centroid
        self.memberIDs = memberIDs
    }
}

/// The split chosen for one language and the evidence behind it.
public struct StyleClustering: Sendable, Equatable {
    public let clusters: [StyleCluster]
    /// Mean simplified silhouette of the chosen split; nil for one style.
    public let silhouette: Double?
    /// Mean of every measured email in the language, the reference the namer
    /// contrasts each style against.
    public let languageMean: StyleAxisValues

    public init(clusters: [StyleCluster], silhouette: Double?, languageMean: StyleAxisValues) {
        self.clusters = clusters
        self.silhouette = silhouette
        self.languageMean = languageMean
    }
}

extension StyleAxisValues {
    /// Root-mean-square distance over the six 0–1 axes, the metric
    /// `similarity(to:)` inverts.
    public func rmsDistance(to other: StyleAxisValues) -> Double {
        let squares = zip(components, other.components).map { ($0 - $1) * ($0 - $1) }
        return (squares.reduce(0, +) / Double(squares.count)).squareRoot()
    }
}
