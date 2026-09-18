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
