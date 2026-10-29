import Foundation

/// Lets the menu bar ask the library window to show something specific.
///
/// The library keeps its own selection state, so without this a menu click
/// could only open the window — landing you on whatever was last selected
/// rather than the meeting you actually clicked.
@MainActor
final class LibraryNavigator: ObservableObject {
    static let shared = LibraryNavigator()

    /// Consumed and cleared by the library window once it has navigated.
    @Published var request: LibrarySelection?

    private init() {}
}


/// Carries the find commands from the menu to whichever view can answer them.
///
/// Counters rather than flags: pressing ⌘F twice in a row has to register
/// twice, and a Bool that is already true says nothing the second time.
@MainActor
final class SearchCoordinator: ObservableObject {
    static let shared = SearchCoordinator()

    @Published private(set) var findRequests = 0
    @Published private(set) var searchAllRequests = 0
    @Published private(set) var nextRequests = 0
    @Published private(set) var previousRequests = 0

    private init() {}

    func find() { findRequests += 1 }
    func searchAll() { searchAllRequests += 1 }
    func next() { nextRequests += 1 }
    func previous() { previousRequests += 1 }
}
