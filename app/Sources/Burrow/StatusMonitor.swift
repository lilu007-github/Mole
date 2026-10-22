import Foundation
import SystemConfiguration
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
    /// The interface with an IP address, kept across snapshots: a one-shot
    /// `mo status --json` caps the list at three interfaces sorted by traffic,
    /// so an idle Wi-Fi can drop out of a single sample.
    private(set) var activeNetwork: StatusSnapshot.Network?
    /// Recent samples for the charts, oldest first.
    private(set) var history: [StatusSample] = []
    private(set) var error: String?
    private var liveViewers = 0
    private var loop: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?

    static let historyLimit = 120

    /// The interface with an IP in this snapshot; otherwise the previous one
    /// (or the system's primary interface) at zero rate, since it was dropped
    /// only for moving no bytes during the sample.
    static func activeNetwork(in snapshot: StatusSnapshot, previous: StatusSnapshot.Network?,
                              primary: () -> StatusSnapshot.Network?) -> StatusSnapshot.Network? {
        if let current = snapshot.network?.first(where: { !($0.ip ?? "").isEmpty }) {
            return current
        }
        guard var idle = previous ?? primary() else { return nil }
        idle.rxRateMbs = 0
        idle.txRateMbs = 0
        return idle
    }

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
            let next = try await MoleCLI.json(["status", "--json"], as: StatusSnapshot.self)
            snapshot = next
            activeNetwork = Self.activeNetwork(in: next, previous: activeNetwork,
                                               primary: PrimaryInterface.current)
            history.append(StatusSample(next, network: activeNetwork))
            Notifier.evaluate(next)
            if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
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

struct StatusSample: Identifiable {
    let date: Date
    let cpu: Double
    let memory: Double
    /// MB/s on the active interface.
    let download: Double
    let upload: Double
    let power: Double?

    var id: Date { date }

    init(_ s: StatusSnapshot, network: StatusSnapshot.Network?, date: Date = .now) {
        self.date = date
        cpu = s.cpu?.usage ?? 0
        memory = s.memory?.usedPercent ?? 0
        download = network?.rxRateMbs ?? 0
        upload = network?.txRateMbs ?? 0
        power = s.thermal?.systemPower.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Asks macOS for the primary IPv4 interface, for when no sample has named it yet.
enum PrimaryInterface {
    static func current() -> StatusSnapshot.Network? {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = global["PrimaryInterface"] as? String,
              let state = SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(name)/IPv4" as CFString) as? [String: Any],
              let ip = (state["Addresses"] as? [String])?.first
        else { return nil }
        return StatusSnapshot.Network(name: name, rxRateMbs: 0, txRateMbs: 0, ip: ip)
    }
}
