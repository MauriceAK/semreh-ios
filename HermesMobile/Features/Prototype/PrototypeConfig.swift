import Foundation

/// Master switch for the chat-only prototype shell.
///
/// Flipping this to `false` restores the full app bit-for-bit: ContentView's
/// logged-in branch mounts the real AppShellView again, and the background
/// work guarded in HermesMobileApp resumes. The prototype files stay compiled
/// but become unreachable.
enum PrototypeConfig {
    static let isEnabled = true
}
