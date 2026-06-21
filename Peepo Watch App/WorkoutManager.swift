import Foundation
import HealthKit

final class WorkoutManager: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    func startBreathingWorkout() {
        lastError = nil

        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "Health data is not available on this device."
            return
        }

        if isRunning {
            return
        }

        let workoutType = HKObjectType.workoutType()
        let status = healthStore.authorizationStatus(for: workoutType)
        if status == .sharingAuthorized {
            beginSession()
            return
        }

        healthStore.requestAuthorization(toShare: [workoutType], read: []) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.beginSession()
                } else {
                    self.lastError = error?.localizedDescription ?? "Health authorization failed."
                }
            }
        }
    }

    func stopWorkout() {
        session?.end()
    }

    private func beginSession() {
        if isRunning {
            return
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .unknown

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)

            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder

            let startDate = Date()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { [weak self] success, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !success {
                        self.lastError = error?.localizedDescription ?? "Failed to start workout collection."
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func finishWorkout(at endDate: Date) {
        guard let builder else {
            resetSession()
            return
        }

        builder.endCollection(withEnd: endDate) { [weak self] _, _ in
            builder.finishWorkout { _, _ in
                DispatchQueue.main.async {
                    self?.resetSession()
                }
            }
        }
    }

    private func resetSession() {
        session = nil
        builder = nil
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        DispatchQueue.main.async {
            switch toState {
            case .running:
                self.isRunning = true
            case .ended:
                self.isRunning = false
                self.finishWorkout(at: date)
            default:
                break
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.lastError = error.localizedDescription
            self.isRunning = false
        }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {}
}
