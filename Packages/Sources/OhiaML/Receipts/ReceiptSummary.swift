// Packages/Sources/OhiaML/Receipts/ReceiptSummary.swift
import Foundation

public struct ReceiptSummary: Sendable, Equatable {
    public let vendor: String
    public let itemDescription: String
    public let amount: String
    public let date: Date
    public let trackingNumber: String?
    public let orderNumber: String?
    public let subscriptionPeriod: String?

    public init(
        vendor: String,
        itemDescription: String,
        amount: String,
        date: Date,
        trackingNumber: String? = nil,
        orderNumber: String? = nil,
        subscriptionPeriod: String? = nil
    ) {
        self.vendor = vendor
        self.itemDescription = itemDescription
        self.amount = amount
        self.date = date
        self.trackingNumber = trackingNumber
        self.orderNumber = orderNumber
        self.subscriptionPeriod = subscriptionPeriod
    }
}
