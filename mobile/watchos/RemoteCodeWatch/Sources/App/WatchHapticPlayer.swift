import WatchKit

final class WatchHapticPlayer {
  func play(transition: PhaseTransition) {
    guard let hapticType = transition.hapticType else { return }
    switch hapticType {
    case .success:
      WKInterfaceDevice.current().play(.success)
    case .failure:
      WKInterfaceDevice.current().play(.failure)
    }
  }
}
