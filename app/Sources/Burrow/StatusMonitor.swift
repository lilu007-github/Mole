import Foundation
import Observation

/// One shared poller for `mo status --json`, used by the Status page and the menu bar.
///
/// Each poll costs roughly half a CPU-second, so it runs every 3 s only while a
/// visible view asks for live data and every 10 s otherwise.
@MainActor
@Observable
final class StatusMonitor {
    static let shared = StatusMonitor()

    private(set) var snapshot: StatusSnapshot?
    private(set) var error: String?
    private var liveViewers = 0
    private var loop: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?

    private var interval: Duration { liveViewers > 0 ? .seconds(3) : .seconds(10) }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                await self.sleep()
            }
        }
    }

    /// Call from onAppear / onDisappear of views that want 3-second updates.
    func beginLive() {
        liveViewers += 1
        start()
        wake?.resume()
        wake = nil
    }

    func endLive() {
        liveViewers = max(liveViewers - 1, 0)
    }

    private func refresh() async {
        do {
            snapshot = try await MoleCLI.json(["status", "--json"], as: StatusSnapshot.self)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Sleeps for the current interval, or until a live viewer appears.
    private func sleep() async {
        let delay = interval
        await withCheckedContinuation { continuation in
            wake = continuation
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                self?.wake?.resume()
                self?.wake = nil
            }
        }
    }
}
