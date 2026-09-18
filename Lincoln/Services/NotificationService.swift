//
//  NotificationService.swift
//  Lincoln
//
//  User notifications for events that need the person's attention (a Duo
//  prompt waiting in the console) or that they would otherwise miss (a
//  tunnel dropped and could not come back).
//

import Foundation
import UserNotifications

@MainActor
protocol Notifying {
    func post(identifier: String, title: String, body: String)
    func clear(identifier: String)
}

@MainActor
final class NotificationService: Notifying {
    private var authorizationRequested = false
    private let isEnabled: () -> Bool

    init(isEnabled: @escaping () -> Bool = { true }) {
        self.isEnabled = isEnabled
    }

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter aborts when the process is not a bundled app.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }

    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested, let center = center else { return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                LogStore.log(level: .warning, category: "Notifications", message: "Authorization failed", details: error.localizedDescription)
            } else {
                LogStore.log(level: .info, category: "Notifications", message: granted ? "Notifications authorized" : "Notifications declined")
            }
        }
    }

    func post(identifier: String, title: String, body: String) {
        guard isEnabled(), let center = center else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error = error {
                LogStore.log(level: .warning, category: "Notifications", message: "Failed to post notification", details: error.localizedDescription)
            }
        }
    }

    func clear(identifier: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [identifier])
        center?.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
