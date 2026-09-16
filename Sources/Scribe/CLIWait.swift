import Foundation

/// The command-line modes run on the main thread before SwiftUI starts, so
/// blocking it — with a semaphore, say — deadlocks anything that needs the main
/// actor, including the meeting library. Pumping the run loop instead keeps the
/// main actor serviceable while we wait.
enum CLIWait {
    static func until(_ isDone: () -> Bool, timeout: TimeInterval = 900) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isDone(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return isDone()
    }
}
