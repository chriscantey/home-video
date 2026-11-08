#if os(macOS)
import AppKit

/// Hold M to see and hear the source, release to come back. A held key's repeats change nothing and
/// are swallowed (an unhandled repeat reaches the
/// system beep), M in a text field is not ours, Command, Option and Control M belong to the
/// menus. Pure, so the rules are testable. The app's local key monitor drives it.
public enum SourceHold {
    /// One phase of the M key.
    public enum Phase: Equatable { case down, `repeat`, up }

    /// What a phase does to the bypass.
    public enum Action: Equatable { case show, hide, swallow, notOurs }

    /// Which phase of the hold an event is, or nil when it is not a bare M outside a text field.
    /// Shift is allowed, so a caps M holds too. A release while the bypass is on is always ours,
    /// even if a text field took focus during the hold, so the bypass is never left on.
    public static func phase(type: NSEvent.EventType, isRepeat: Bool, characters: String?,
                             modifiers: NSEvent.ModifierFlags, textFieldHasFocus: Bool,
                             holding: Bool = false) -> Phase? {
        guard characters?.lowercased() == "m",
              modifiers.intersection([.command, .option, .control]).isEmpty else { return nil }
        switch type {
        case .keyDown: return textFieldHasFocus ? nil : (isRepeat ? .repeat : .down)
        case .keyUp: return textFieldHasFocus && !holding ? nil : .up
        default: return nil
        }
    }

    /// What one phase does: down shows, up hides, a repeat is handled and does nothing, so
    /// holding the key is one press and one release however long it is held.
    public static func action(_ phase: Phase?) -> Action {
        switch phase {
        case .down: return .show
        case .up: return .hide
        case .repeat: return .swallow
        case nil: return .notOurs
        }
    }
}
#endif
