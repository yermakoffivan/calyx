// TabClickRecognizer.swift
// Calyx
//
// AppKit-backed click container for tab items. Replaces SwiftUI's
// `onTapGesture` + `TapGesture(count: 2)` combination, which forced
// SwiftUI to wait `NSEvent.doubleClickInterval` (~500 ms) before firing
// a single click. Using AppKit's native `mouseDown(with:)` we receive
// `clickCount` synchronously and can fire single/double click handlers
// with zero artificial latency.
//
// IMPORTANT (container, not background):
// Earlier revisions placed the recognizer as `.background(...)` of the
// SwiftUI tab content. That fails: SwiftUI's `.contentShape(Rectangle())`
// on the foreground HStack claims hits, and `.background` is treated as
// a decoration layer that never receives `mouseDown`. The fix is to make
// the AppKit view the *container* that hosts the SwiftUI content via
// `NSHostingView`, so AppKit owns the topmost view in the hierarchy and
// gets `mouseDown(with:)` first.
//
// Behavior:
// - clickCount == 1 on tab body -> onSingleClick()
// - clickCount == 2 on tab body -> onDoubleClick()
// - clickCount on a trailing-edge rect (close button first, then
//   trailingActions in order; disabled rects are transparent) -> that
//   rect's action
//   (Ctrl+click on this rect opens the context menu instead; see below)
// - clickCount >= 3 -> ignored
// - right-click / Ctrl+click -> context menu from contextMenuProvider,
//   not gated on isEnabled: this check runs before the close-button
//   geometry test, so Ctrl+click anywhere on the tab, including the
//   close-button rect, opens the context menu rather than closing the
//   tab, matching a plain right-click on the same spot. A rename in
//   progress is committed by the
//   inline editor's own click monitor (`InlineTextField`, installed
//   0.3s after the editor opens) when any mouse button is pressed
//   outside its field, so the menu normally opens on an already
//   committed tab. In the brief window before that monitor exists (0.3s
//   after an editor opens), the menu opens over the live editor: Close
//   Tab closes the tab exactly as the keyboard shortcut would, and
//   Rename on the same host is a no-op, but choosing Rename on the
//   other host commits the first editor's typed title and then
//   overwrites it with the second editor's stale snapshot.
//   `InlineTextField` snapshots `initialText` in `makeNSView`, and the
//   first editor only commits when the second one takes focus
//   (`InlineEditorTextField.viewDidMoveToWindow` -> `selectText`), so
//   the second editor opens already holding the first editor's
//   pre-commit title and overwrites it on commit. The same sequence
//   already exists for a double-click on the other host inside that
//   window; the monitor's install delay is `InlineTextField`'s.
// - right-click while the left mouse button is held -> no menu
//
// Trailing-edge dispatch (geometry-based, AppKit-only):
// - The close button is rendered as a *visual-only* `Image(systemName:)`
//   inside the SwiftUI HStack. There is NO SwiftUI `Button` for the
//   close hit. Instead, `mouseDown(with:)` computes a frame for the
//   close-button area (right-aligned 16x16 box, inset
//   `closeButtonInsetFromTrailing` from the trailing edge) and, when
//   `closeButtonEnabled == true`, fires `onClose()` directly when the
//   click lands inside that rect.
// - Rationale: routing the close click through SwiftUI's
//   `Button { } .overlay(alignment: .trailing)` was unreliable. The
//   SwiftUI compositing layer (`PlatformGroupContainer`) ate roughly
//   half of the close-button mouseDown events on the very same screen
//   coordinate. Owning the hit math in AppKit removes that variance.
// - The same mechanism generalizes past the close button via
//   `TrailingAction`: the sidebar group header's close-all and collapse
//   glyphs are the second user, each a visual-only image hit-tested as
//   its own trailing-edge rect.
//
// Drag tracking:
// - Drag tracking is performed in `mouseDragged(with:)` and
//   `mouseUp(with:)` (NOT a SwiftUI `DragGesture`). A SwiftUI
//   `.gesture(...)` on an ancestor view spawns a
//   `PlatformGroupContainer` compositing layer whose
//   `mouseDown(with:)` is a no-op, and that layer can intercept
//   clicks before they reach our `ClickContainerNSView`. Doing the
//   reorder drag in AppKit eliminates that compositing layer entirely.
// - Cancel path: AppKit delivers the drag's mouseDragged/mouseUp to the
//   view instance that received the mouseDown. If that instance leaves
//   its window mid-drag (e.g. the hosting SwiftUI row is torn down by a
//   model change), the mouseUp never reaches it, `onDragEnded` never
//   fires, and the caller's drag state (offset row, frozen layout) would
//   stay live indefinitely. `viewWillMove(toWindow: nil)` therefore
//   clears the press/drag state and calls `onDragCancelled` instead, so
//   the caller can reset without performing a drop. It never calls
//   `onDragEnded`: a drop resolved against a view that is going away
//   would act on a stale layout. A press that never crossed the drag
//   threshold has nothing to cancel and is left alone.
//
// Generics:
// - Swift NSObject subclasses cannot be generic. The container NSView
//   (`ClickContainerNSView`) is therefore non-generic and stores
//   `NSHostingView<AnyView>`. The outer `TabClickContainer` is generic
//   over `Content: View` for ergonomic call sites and erases to AnyView
//   on the way in. The single AnyView wrap is identical to the work
//   SwiftUI does for `@ViewBuilder` closures and is not a measurable
//   cost.

import AppKit
import SwiftUI

/// A click target at the trailing edge of the container, hit-tested in
/// AppKit instead of by a SwiftUI Button (a hosted Button receives the
/// press before the container and swallows Ctrl+click, so the context
/// menu could never open over it). The rect is `size` square, vertically
/// centered, `insetFromTrailing` points from the trailing edge.
struct TrailingAction {
    var insetFromTrailing: CGFloat
    var size: CGFloat
    var isEnabled: Bool
    var action: () -> Void
}

struct TabClickContainer<Content: View>: NSViewRepresentable {
    let isEnabled: Bool
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void
    let onClose: (() -> Void)?
    let closeButtonEnabled: Bool
    let closeButtonInsetFromTrailing: CGFloat
    let closeButtonSize: CGFloat
    let trailingActions: [TrailingAction]
    let onDragChanged: ((CGSize) -> Void)?
    let onDragEnded: (() -> Void)?
    let onDragCancelled: (() -> Void)?
    let contextMenu: (() -> NSMenu?)?
    let content: Content

    init(
        isEnabled: Bool,
        onSingleClick: @escaping () -> Void,
        onDoubleClick: @escaping () -> Void,
        onClose: (() -> Void)? = nil,
        closeButtonEnabled: Bool = false,
        closeButtonInsetFromTrailing: CGFloat = 14,
        closeButtonSize: CGFloat = 16,
        trailingActions: [TrailingAction] = [],
        onDragChanged: ((CGSize) -> Void)? = nil,
        onDragEnded: (() -> Void)? = nil,
        onDragCancelled: (() -> Void)? = nil,
        contextMenu: (() -> NSMenu?)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.isEnabled = isEnabled
        self.onSingleClick = onSingleClick
        self.onDoubleClick = onDoubleClick
        self.onClose = onClose
        self.closeButtonEnabled = closeButtonEnabled
        self.closeButtonInsetFromTrailing = closeButtonInsetFromTrailing
        self.closeButtonSize = closeButtonSize
        self.trailingActions = trailingActions
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        self.onDragCancelled = onDragCancelled
        self.contextMenu = contextMenu
        self.content = content()
    }

    func makeNSView(context: Context) -> ClickContainerNSView {
        let view = ClickContainerNSView()
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.hostingView = hosting
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        view.onClose = onClose
        view.closeButtonEnabled = closeButtonEnabled
        view.closeButtonInsetFromTrailing = closeButtonInsetFromTrailing
        view.closeButtonSize = closeButtonSize
        view.trailingActions = trailingActions
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.onDragCancelled = onDragCancelled
        view.contextMenuProvider = contextMenu
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: ClickContainerNSView, context: Context) {
        nsView.hostingView?.rootView = AnyView(content)
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
        nsView.onClose = onClose
        nsView.closeButtonEnabled = closeButtonEnabled
        nsView.closeButtonInsetFromTrailing = closeButtonInsetFromTrailing
        nsView.closeButtonSize = closeButtonSize
        // Load-bearing: these closures capture call-site SwiftUI state
        // (e.g. a hover flag, a collapsed flag) that changes across view
        // updates, so the array must be re-pushed here, not only in
        // `makeNSView`.
        nsView.trailingActions = trailingActions
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.onDragCancelled = onDragCancelled
        nsView.contextMenuProvider = contextMenu
        nsView.isEnabled = isEnabled
    }

    // NOTE: We deliberately omit a custom `sizeThatFits(_:nsView:context:)`.
    // The pinned-edge constraints between the container and its
    // NSHostingView make the container adopt the SwiftUI subtree's
    // intrinsic size automatically. NSViewRepresentable forwards
    // `intrinsicContentSize` from the NSView to SwiftUI by default,
    // which in turn comes from the SwiftUI content's own
    // `.frame(minWidth: 72, maxWidth: 180)` etc.
}

@MainActor
final class ClickContainerNSView: NSView {
    var hostingView: NSHostingView<AnyView>?
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Called instead of `onDragEnded` when the view leaves its window
    /// mid-drag. See "Cancel path" in the header comment.
    var onDragCancelled: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    var isEnabled: Bool = true

    /// `true` when the close-button rect should consume clicks. Caller
    /// usually wires this to `(isHovering || isActive) && !isEditing`,
    /// matching the SwiftUI visual visibility/opacity of the xmark icon.
    var closeButtonEnabled: Bool = false

    /// Right-edge inset of the close-button rect (in this view's local
    /// coordinates), matching the SwiftUI `.padding(.horizontal, 14)`
    /// applied to the HStack that hosts the visual xmark icon.
    var closeButtonInsetFromTrailing: CGFloat = 14

    /// Side length of the close-button rect, matching the
    /// `.frame(width: 16, height: 16)` on the SwiftUI xmark icon.
    var closeButtonSize: CGFloat = 16

    /// Additional AppKit-hit-tested rects at the trailing edge, checked
    /// after the close-button rect. See `TrailingAction`.
    var trailingActions: [TrailingAction] = []

    /// Threshold (in points) above which a press becomes a drag.
    /// Mirrors SwiftUI's default `DragGesture(minimumDistance: 5)`.
    private static let dragThreshold: CGFloat = 5

    /// Mouse-down location in *window* coordinates (NOT this view's
    /// local space). Used to compute drag translation deltas in
    /// `mouseDragged(with:)`. `nil` outside an active press.
    ///
    /// Why window coordinates, not local: while a reorder drag is in
    /// progress the SwiftUI ancestor applies `.offset(x: dragOffset)`
    /// to this entire tab view, so `self`'s window-space origin moves
    /// with the cursor. Computing the delta in *local* coordinates
    /// would subtract that motion from the cursor delta, cancelling
    /// (or overshooting) the translation each frame and producing a
    /// visible vibration as soon as the dragged tab overlapped a
    /// neighbour and the reorder offset began updating. Window space
    /// is stationary during the drag, so deltas are stable.
    private var mouseDownLocationInWindow: NSPoint?

    /// `true` once the cursor has moved more than `dragThreshold`
    /// points away from `mouseDownLocationInWindow` during a press.
    /// Reset on `mouseUp`.
    private var isDragging: Bool = false

    /// `true` if the active press began on the tab body (i.e. not on
    /// a SwiftUI subview such as the close button). Drag tracking
    /// only activates for tab-body presses.
    private var pressTargetsTabBody: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }

    override func rightMouseDown(with event: NSEvent) {
        // No context menu while the left button is held: the menu's tracking
        // loop would consume the left mouseUp that ends a press or reorder
        // drag, leaving this view's press state and the SwiftUI reorder state
        // stuck on the dragged tab.
        guard NSEvent.pressedMouseButtons & 0x1 == 0 else { return }
        super.rightMouseDown(with: event)
    }

    /// Computes a trailing-edge rect in this view's local (flipped)
    /// coordinate space: right-aligned with `inset` between its trailing
    /// edge and `bounds.maxX`, `size` square, vertically centred. This
    /// mirrors how a SwiftUI `Image(systemName:)` is laid out as a
    /// trailing child of a horizontally-padded HStack.
    private func trailingRect(insetFromTrailing inset: CGFloat, size: CGFloat) -> CGRect {
        CGRect(
            x: bounds.maxX - inset - size,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )
    }

    /// Resolves the trailing-edge click target at `point` (this view's
    /// local, flipped coordinates), if any. The close button is checked
    /// first (when `onClose` is set and `closeButtonEnabled` is true),
    /// then `trailingActions` in order. Disabled rects are transparent:
    /// a point inside one resolves to `nil`, not to the disabled action.
    func trailingAction(at point: CGPoint) -> TrailingAction? {
        if onClose != nil, closeButtonEnabled {
            let rect = trailingRect(insetFromTrailing: closeButtonInsetFromTrailing, size: closeButtonSize)
            if rect.contains(point) {
                return TrailingAction(
                    insetFromTrailing: closeButtonInsetFromTrailing,
                    size: closeButtonSize,
                    isEnabled: true,
                    action: { [weak self] in self?.onClose?() }
                )
            }
        }

        for candidate in trailingActions {
            guard candidate.isEnabled else { continue }
            let rect = trailingRect(insetFromTrailing: candidate.insetFromTrailing, size: candidate.size)
            if rect.contains(point) {
                return candidate
            }
        }

        return nil
    }

    override func mouseDown(with event: NSEvent) {
        // Local (flipped) coordinate is needed for the close-button
        // hit-test only. Drag tracking uses window coordinates instead;
        // see `mouseDownLocationInWindow` for the rationale.
        let pointInSelf = convert(event.locationInWindow, from: nil)

        // Reset drag state on every fresh press.
        mouseDownLocationInWindow = event.locationInWindow
        isDragging = false
        pressTargetsTabBody = false

        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            // Clear the press location before popping the menu: its tracking
            // loop usually consumes the matching mouseUp, so no mouseUp may
            // arrive to clear it.
            mouseDownLocationInWindow = nil
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }

        guard isEnabled else {
            super.mouseDown(with: event)
            return
        }

        // 1. Trailing-edge geometry test.
        //
        // The close button and any other trailing glyphs (e.g. a group
        // header's collapse chevron) are rendered as visual-only SwiftUI
        // Images (no Button, no onTapGesture). We own their hit math
        // ourselves via `trailingAction(at:)`. This bypasses the
        // unstable SwiftUI `PlatformGroupContainer` dispatch path that
        // previously ate ~50% of close clicks, and also the fact that a
        // hosted Button, had one been used instead, receives the press
        // before this view and would swallow it.
        if let target = trailingAction(at: pointInSelf) {
            target.action()
            // Fully consume the event: do NOT forward to super and
            // do NOT engage drag tracking. The next press will
            // start a fresh `mouseDownLocationInWindow`.
            mouseDownLocationInWindow = nil
            return
        }

        // 2. Subview hit-test fallback.
        //
        // In the geometry-only design there should normally be no
        // interactive SwiftUI subview, but we still honour any rare
        // descendant hit (e.g. an inline text field while editing).
        // Note: NSView.hitTest expects the point in *superview*
        // coordinates, so use locationInWindow converted via the
        // superview, not via `self`.
        let pointInSuper = superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        let hit = super.hitTest(pointInSuper)

        if let hit, hit !== self, hit !== hostingView {
            super.mouseDown(with: event)
            return
        }

        // 3. Tab body branch.
        //
        // The hit is our own view (or the bare hosting view, i.e. the
        // tab body chrome with no interactive subview underneath).
        // Fire single/double click handlers based on AppKit's
        // synchronous click count.
        pressTargetsTabBody = true
        switch event.clickCount {
        case 1:
            onSingleClick?()
        case 2:
            onDoubleClick?()
        default:
            break
        }

        // Do NOT forward `super.mouseDown(with:)` here when the press
        // is on the tab body. Forwarding would let NSHostingView /
        // SwiftUI install its own gesture machinery on top of ours,
        // re-introducing the `PlatformGroupContainer` interception
        // that this whole class is designed to bypass. Drag tracking
        // happens locally via `mouseDragged(with:)` below.
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, pressTargetsTabBody, let start = mouseDownLocationInWindow else {
            super.mouseDragged(with: event)
            return
        }

        // Compute the delta in *window* coordinates. The window itself
        // does not move during a drag, so this is a stable reference
        // frame even when `self` is being translated by the SwiftUI
        // ancestor's `.offset(x: dragOffset)` modifier.
        let current = event.locationInWindow
        let dx = current.x - start.x
        // Y-axis convention bridge:
        //   * NSWindow coordinate space:        +y points UP.
        //   * SwiftUI `DragGesture.translation`: +y points DOWN.
        // The downstream consumers (e.g. sidebar vertical drag) expect
        // SwiftUI semantics, so flip the sign: a downward cursor move
        // (smaller window-y) becomes a positive dy.
        let dy = start.y - current.y

        if !isDragging {
            // Activate drag once we cross the threshold along either axis,
            // matching SwiftUI's default `minimumDistance: 5`.
            let magnitude = (dx * dx + dy * dy).squareRoot()
            if magnitude < Self.dragThreshold {
                return
            }
            isDragging = true
        }

        onDragChanged?(CGSize(width: dx, height: dy))
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = isDragging
        // Reset state before invoking callbacks so re-entrant updates
        // observe a clean baseline.
        mouseDownLocationInWindow = nil
        isDragging = false
        let wasTabBody = pressTargetsTabBody
        pressTargetsTabBody = false

        if wasDragging && wasTabBody {
            onDragEnded?()
        }

        super.mouseUp(with: event)
    }

    /// Cancels an in-flight drag when the view is removed from its window:
    /// the mouseUp that would end it can no longer arrive (see "Cancel
    /// path" in the header comment). State is cleared before the callback,
    /// as in `mouseUp`, so a re-entrant update or a stray later mouseUp
    /// sees no drag and cannot end it a second time.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil, isDragging, pressTargetsTabBody else { return }
        mouseDownLocationInWindow = nil
        isDragging = false
        pressTargetsTabBody = false
        onDragCancelled?()
    }
}
