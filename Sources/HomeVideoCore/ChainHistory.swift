import Foundation

/// Undo and redo over the chain's settings.
///
/// The history holds whole states, never single edits: the app records the chain's settings
/// (`SettingsClipboard.encode`, the string Reset compares against) after every change its
/// settings observer sees, so a Look, a stage preset, a switch, a slider, Framing, the Output
/// size, Reset, Shuffle and an imported preset all land here through the one path. A change
/// made while one mouse press is held (a slider drag) folds into a single step, whose redo is
/// the value at mouse up. Undo hands back the state to put on the chain, and the app reports
/// what the chain then reads with `settle`, so putting it back is never recorded as a change.
/// The open clip and the play head are not in the state, so undo never moves either.
public final class ChainHistory<State: Equatable> {
    /// The most steps kept. The oldest goes first.
    public static var depth: Int { 200 }

    /// The states before each step, the newest last.
    public private(set) var undoStack: [State] = []
    /// The states undone, the next redo last.
    public private(set) var redoStack: [State] = []
    /// What the chain holds now, as the history last saw it.
    public private(set) var current: State
    /// The mouse press the newest step was made under, while that step may still grow.
    private var openGesture: Int?

    public init(_ state: State) {
        current = state
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// The chain changed to `state`. `gesture` names the mouse press it happened under (nil for
    /// a key, a menu item or anything else with no press held): a change under the same press
    /// as the step before it moves that step's end instead of making a new step.
    public func record(_ state: State, gesture: Int? = nil) {
        guard state != current else { return }
        if let gesture, gesture == openGesture, !undoStack.isEmpty {
            current = state
            return
        }
        undoStack.append(current)
        if undoStack.count > Self.depth { undoStack.removeFirst(undoStack.count - Self.depth) }
        redoStack.removeAll()
        current = state
        openGesture = gesture
    }

    /// The state to put on the chain to step back, nil when there is none.
    public func undo() -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        current = previous
        openGesture = nil
        return previous
    }

    /// The state to put on the chain to step forward again, nil when there is none.
    public func redo() -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        current = next
        openGesture = nil
        return next
    }

    /// After an undo or redo was put on the chain: what the chain reads now, taken as the
    /// current state without a step.
    public func settle(_ state: State) {
        current = state
        openGesture = nil
    }

    /// A new starting point with nothing to undo or redo.
    public func rebase(_ state: State) {
        undoStack.removeAll()
        redoStack.removeAll()
        settle(state)
    }
}
