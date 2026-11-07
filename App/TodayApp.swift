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
            // Sheets are presented from above the tab view, so the tint has to
            // be set here to reach their buttons and text-field carets.
            RootView().tint(Color.ink)
        }
    }
}
