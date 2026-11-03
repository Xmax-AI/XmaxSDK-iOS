import Foundation
import XmaxSDK

struct FeedCreditBalanceState: Equatable, Sendable {
    var balance: Double?
    var isLoading = false
    var refreshFailed = false
}

/// Polls only for the visible, active homepage and rejects results from replaced API credentials.
@MainActor
final class FeedCreditBalancePoller {
    typealias Query = @Sendable () async throws -> Double
    typealias QueryFactory = @Sendable (String, XmaxEnvironment) -> Query
    typealias Wait = @Sendable (UInt64) async throws -> Void

    private struct Account: Equatable {
        let key: String
        let environment: XmaxEnvironment
    }

    private let makeQuery: QueryFactory
    private let wait: Wait
    private var account: Account?
    private var task: Task<Void, Never>?
    private var revision: UInt64 = 0
    private(set) var state = FeedCreditBalanceState()
    var onChange: ((FeedCreditBalanceState) -> Void)?

    init(
        makeQuery: @escaping QueryFactory = { key, environment in
            let client = XmaxClient(
                configuration: XmaxConfiguration(apiKey: key, environment: environment)
            )
            return { try await client.getCreditBalance().currentBalance }
        },
        wait: @escaping Wait = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.makeQuery = makeQuery
        self.wait = wait
    }

    deinit { task?.cancel() }

    func update(apiKey: String, environment: XmaxEnvironment, isActive: Bool) {
        let next = Account(
            key: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            environment: environment
        )
        if next != account {
            pause()
            account = next
            publish(FeedCreditBalanceState())
        }
        guard isActive, !next.key.isEmpty else {
            pause()
            return
        }
        guard task == nil else { return }
        revision &+= 1
        let request = revision
        let makeQuery = makeQuery
        let wait = wait
        task = Task { [weak self] in
            // Coalesce API-key editing without retaining the controller during network or timer waits.
            do { try await wait(250_000_000) } catch { return }
            guard !Task.isCancelled, self?.revision == request else { return }
            let query = makeQuery(next.key, next.environment)
            while !Task.isCancelled, self?.revision == request {
                self?.publish(FeedCreditBalanceState(balance: self?.state.balance, isLoading: true))
                do {
                    let balance = try await query()
                    guard !Task.isCancelled, self?.revision == request else { return }
                    self?.publish(FeedCreditBalanceState(balance: balance))
                } catch {
                    guard !Task.isCancelled, self?.revision == request else { return }
                    self?.publish(
                        FeedCreditBalanceState(balance: self?.state.balance, refreshFailed: true)
                    )
                }
                do { try await wait(5_000_000_000) } catch { return }
            }
        }
    }

    private func pause() {
        revision &+= 1
        task?.cancel()
        task = nil
        if state.isLoading {
            var paused = state
            paused.isLoading = false
            publish(paused)
        }
    }

    private func publish(_ state: FeedCreditBalanceState) {
        self.state = state
        onChange?(state)
    }
}

func formatFeedCreditBalance(_ balance: Double?) -> String {
    guard let balance else { return "—" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 6
    return formatter.string(from: NSNumber(value: balance)) ?? "—"
}
