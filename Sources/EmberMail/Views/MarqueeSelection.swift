import AppKit
import SwiftUI

/// Finder-style selection helpers for a SwiftUI `List` (which is an NSTableView underneath):
///  • Shift + drag      → rubber-band ("marquee") selection, added to what's already selected
///  • Shift + click     → select the range from the last clicked row
///  • ⌘ + click / click → handled natively by the List
/// Attach as an `.overlay`; the view itself never intercepts the mouse (hitTest is nil).
struct MarqueeSelection: NSViewRepresentable {
    /// Row ids in display order (one per table row).
    var orderedIDs: () -> [String]
    var currentSelection: () -> Set<String>
    var onChange: (Set<String>) -> Void

    func makeNSView(context: Context) -> MarqueeView {
        let view = MarqueeView()
        update(view)
        return view
    }

    func updateNSView(_ view: MarqueeView, context: Context) { update(view) }

    private func update(_ view: MarqueeView) {
        view.orderedIDs = orderedIDs
        view.currentSelection = currentSelection
        view.onChange = onChange
    }
}

final class MarqueeView: NSView {
    var orderedIDs: () -> [String] = { [] }
    var currentSelection: () -> Set<String> = { [] }
    var onChange: (Set<String>) -> Void = { _ in }

    private var monitor: Any?
    private weak var table: NSTableView?
    /// Mouse-down point in table coordinates (so scrolling during a drag stays consistent).
    private var startInTable: NSPoint?
    private var clickedRow = -1
    private var baseSelection: Set<String> = []
    private var didDrag = false
    private var anchorID: String?
    private var marquee: NSRect?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    deinit { removeMonitor() }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: Events

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        switch event.type {
        case .leftMouseDown: return mouseDown(event, in: window)
        case .leftMouseDragged: return mouseDragged(event)
        case .leftMouseUp: return mouseUp(event)
        default: return event
        }
    }

    private func mouseDown(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        startInTable = nil
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local), window.attachedSheet == nil,
              let table = tableView(at: event.locationInWindow) else { return event }
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard flags.contains(.shift), !flags.contains(.command), !flags.contains(.option) else {
            // Plain or ⌘ click: let the list handle it, but remember the row as the shift-click anchor.
            let ids = orderedIDs()
            if row >= 0, row < ids.count { anchorID = ids[row] }
            return event
        }
        // Shift: we decide between "click" (range) and "drag" (marquee) on mouse-up / movement.
        self.table = table
        startInTable = point
        clickedRow = row
        baseSelection = currentSelection()
        didDrag = false
        window.makeFirstResponder(table)
        return nil
    }

    private func mouseDragged(_ event: NSEvent) -> NSEvent? {
        guard let start = startInTable, let table else { return event }
        let point = table.convert(event.locationInWindow, from: nil)
        if !didDrag && hypot(point.x - start.x, point.y - start.y) < 4 { return nil }
        didDrag = true
        // At least 1 pt in each direction: a perfectly straight drag would otherwise have zero area.
        let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: max(1, abs(point.x - start.x)), height: max(1, abs(point.y - start.y)))
        marquee = convert(rect, from: table)
        needsDisplay = true

        let ids = orderedIDs()
        let range = table.rows(in: rect)
        var hit = Set<String>()
        if range.length > 0 {
            for index in range.location..<NSMaxRange(range) where index < ids.count { hit.insert(ids[index]) }
        }
        onChange(baseSelection.union(hit))
        return nil
    }

    private func mouseUp(_ event: NSEvent) -> NSEvent? {
        guard startInTable != nil else { return event }
        defer {
            startInTable = nil
            marquee = nil
            needsDisplay = true
        }
        guard !didDrag else { return nil }
        // Plain shift-click: select from the anchor row to the clicked row.
        let ids = orderedIDs()
        guard clickedRow >= 0, clickedRow < ids.count else { return nil }
        let selection = currentSelection()
        let anchorIndex = anchorID.flatMap { ids.firstIndex(of: $0) }
            ?? ids.firstIndex(where: { selection.contains($0) })
            ?? clickedRow
        let range = min(anchorIndex, clickedRow)...max(anchorIndex, clickedRow)
        onChange(selection.union(ids[range]))
        if anchorID == nil { anchorID = ids[anchorIndex] }
        return nil
    }

    /// The NSTableView under the mouse (the message list, since we only act inside our own bounds).
    private func tableView(at windowPoint: NSPoint) -> NSTableView? {
        var view = window?.contentView?.superview?.hitTest(windowPoint)
        while let current = view {
            if let table = current as? NSTableView { return table }
            view = current.superview
        }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let marquee else { return }
        let accent = NSColor(red: 0.89, green: 0.40, blue: 0.18, alpha: 1)
        accent.withAlphaComponent(0.14).setFill()
        marquee.fill()
        accent.withAlphaComponent(0.85).setStroke()
        let path = NSBezierPath(rect: marquee.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}
