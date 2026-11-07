import Foundation

public extension Notification.Name {
    /// Wake-up hint posted on the main actor when the SMTP server has accepted
    /// an outgoing message — the confirmed-send moment. The authoritative record
    /// is the `sentConfirmationPendingPlayback` flag the OutboxWorker persists on
    /// the `OutboxItem` row; this notification only nudges the app to read and
    /// consume that flag (which is what actually plays the sent-mail sound, once).
    /// A dropped hint self-heals via the app's launch sweep of the pending flag.
    ///
    /// userInfo: `MailSendNotificationUserInfoKey.outboxItemID` → the opaque
    /// outbox row UUID string. Carries no Message-ID or account address, so a
    /// spoofed notification fails the row lookup and no message metadata is
    /// broadcast.
    static let ohiaMailSendConfirmed = Notification.Name("ohia.mail.sendConfirmed")
}

public enum MailSendNotificationUserInfoKey {
    /// Opaque UUID of the `OutboxItem` whose send was confirmed. The app looks
    /// the row up and validates its pending-playback flag before sounding.
    public static let outboxItemID = "outboxItemID"
}
