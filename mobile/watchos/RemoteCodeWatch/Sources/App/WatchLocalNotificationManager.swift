import UserNotifications

final class WatchLocalNotificationManager {
  func requestAuthorization() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func scheduleIfNeeded(snapshot: LiveActivitySharedSnapshot, phase: LiveActivitySharedPhase) {
    guard let content = makeNotificationContent(
      chatId: snapshot.chatId,
      chatTitle: snapshot.chatTitle,
      phase: phase
    ) else { return }

    let unContent = UNMutableNotificationContent()
    unContent.title = content.title
    unContent.body = content.body
    unContent.sound = .default

    let request = UNNotificationRequest(
      identifier: content.identifier,
      content: unContent,
      trigger: nil
    )

    UNUserNotificationCenter.current().add(request) { _ in }
  }
}
