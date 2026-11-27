import Foundation
import UserNotifications

/// Local reminders at each post's scheduled time. Tapping one opens that post, caption ready.
/// Runs on the phone, so it works asleep or offline; nothing posts without you.
@MainActor
final class PostReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PostReminders()
    private let center = UNUserNotificationCenter.current()
    nonisolated private static let key = "postPlan"

    /// Call once at launch so taps on reminders reach the app.
    func activate() { center.delegate = self }

    /// Asks for notification permission the first time a reminder is wanted.
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func update(_ plan: PostPlan) {
        let id = plan.id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard plan.remind, !plan.isPosted, plan.scheduledAt > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Time to post: \(plan.title)"
        let left = plan.posts.filter { !$0.isPosted }.map(\.platform.name)
        content.body = plan.hasVideo
            ? "Your video and caption are ready for \(Self.list(left)). Tap to post."
            : "This one still needs a video. Tap to see the plan."
        content.sound = .default
        content.userInfo = [Self.key: id]

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: plan.scheduledAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        // iOS asks for permission only the first time; after that this returns at once.
        Task {
            guard await requestPermission() else { return }
            // Skip if the post changed while waiting; the newer save schedules its own reminder.
            guard PostStore.shared.plan(plan.id) == plan else { return }
            try? await center.add(request)
        }
    }

    func cancel(_ id: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "posting"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo[Self.key] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            AppRouter.shared.tab = .post
            AppRouter.shared.openPostPlan = id
        }
    }
}
