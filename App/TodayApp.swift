import SwiftUI
import UserNotifications

@main
struct TodayApp: App {
    /// Must be set before the app finishes launching, or a notification that
    /// arrives while the app is open is dropped without a banner.
    init() {
        UNUserNotificationCenter.current().delegate = NotifyPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
