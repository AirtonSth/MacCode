import Foundation
import Sparkle

@MainActor
public enum AppUpdateAvailability: Equatable {
    case unknown
    case checking
    case available
    case upToDate
    case failed(String)
}

@MainActor
public protocol AppUpdateChecking: AnyObject {
    var availability: AppUpdateAvailability { get }
    var onAvailabilityChanged: ((AppUpdateAvailability) -> Void)? { get set }
    func checkForUpdates()
}

@MainActor
public final class SparkleAppUpdater: AppUpdateChecking {
    public private(set) var availability: AppUpdateAvailability = .unknown {
        didSet { onAvailabilityChanged?(availability) }
    }
    public var onAvailabilityChanged: ((AppUpdateAvailability) -> Void)?

    private let updaterController: SPUStandardUpdaterController
    private var observers: [NSObjectProtocol] = []

    public static func defaultIfConfigured(bundle: Bundle = .main) -> SparkleAppUpdater? {
        guard let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return SparkleAppUpdater()
    }

    public init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        observeUpdateNotifications()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    public func checkForUpdates() {
        availability = .checking
        updaterController.checkForUpdates(nil)
    }

    private func observeUpdateNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .SUUpdaterDidFindValidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let updater = self else { return }
            Task { @MainActor in updater.availability = .available }
        })
        observers.append(center.addObserver(
            forName: .SUUpdaterDidNotFindUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let updater = self else { return }
            Task { @MainActor in updater.availability = .upToDate }
        })
    }
}
