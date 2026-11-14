import AppKit
import Observation

/// A pane that a window's sidebar lists.
struct SidebarRow: Equatable {
    enum Icon: Equatable {
        case symbol(String)
        /// An image in the app's resources that is drawn in the sidebar's color, as symbols are.
        case template(String)
    }

    /// The pane that the window shows while the row is selected.
    let pane: AnyHashable
    let title: String
    let icon: Icon
}

/// Rows of a sidebar under one heading, or at its top without one.
struct SidebarGroup: Equatable {
    let title: String?
    let rows: [SidebarRow]
}

/// The sidebar of a window: an outline of the panes that the window can show, grouped under headings.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Node: NSObject {
        let heading: String?
        let row: SidebarRow?
        let children: [Node]

        init(heading: String? = nil, row: SidebarRow? = nil, children: [Node] = []) {
            self.heading = heading
            self.row = row
            self.children = children
        }
    }

    private let groups: @MainActor () -> [SidebarGroup]
    private let selection: @MainActor () -> AnyHashable?
    private let select: @MainActor (AnyHashable) -> Void
    private let outline = NSOutlineView()
    private var shownGroups: [SidebarGroup]?
    private var nodes: [Node] = []
    /// Whether this controller changes the selection, which is then not the person's choice.
    private var isUpdating = false

    /// - Parameters:
    ///   - groups: The rows to list. The sidebar lists them again when the observable values that this reads change.
    ///   - selection: The pane that the window shows.
    ///   - select: Shows the pane of the row that the person selected.
    init(
        groups: @escaping @MainActor () -> [SidebarGroup], selection: @escaping @MainActor () -> AnyHashable?,
        select: @escaping @MainActor (AnyHashable) -> Void
    ) {
        self.groups = groups
        self.selection = selection
        self.select = select
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Pane"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Sidebar")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outline
        view = scroll
        update()
    }

    /// Lists the current rows and selects the shown pane's row, then waits for either to change.
    private func update() {
        withObservationTracking {
            let groups = groups()
            let selection = selection()
            isUpdating = true
            defer { isUpdating = false }
            if groups != shownGroups {
                shownGroups = groups
                nodes = groups.flatMap { group in
                    let rows = group.rows.map { Node(row: $0) }
                    return group.title.map { [Node(heading: $0, children: rows)] } ?? rows
                }
                outline.reloadData()
                outline.expandItem(nil, expandChildren: true)
            }
            let row = (nodes + nodes.flatMap(\.children)).first { $0.row?.pane == selection }.map(outline.row(forItem:)) ?? -1
            if row != outline.selectedRow {
                outline.selectRowIndexes(row < 0 ? [] : [row], byExtendingSelection: false)
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.update() }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? nodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.heading != nil
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Node)?.heading != nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Node)?.row != nil
    }

    // Every group stays open: a window lists a few panes, and a closed group would hide the selected one.
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let identifier = NSUserInterfaceItemIdentifier(node.heading == nil ? "Row" : "Heading")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier, hasImage: node.heading == nil)
        cell.textField?.stringValue = node.heading ?? node.row?.title ?? ""
        switch node.row?.icon {
        case .symbol(let name): cell.imageView?.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .template(let name):
            let image = Bundle.module.image(forResource: name)
            image?.isTemplate = true
            cell.imageView?.image = image
        case nil: break
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdating, let pane = (outline.item(atRow: outline.selectedRow) as? Node)?.row?.pane else { return }
        select(pane)
    }

    private static func makeCell(_ identifier: NSUserInterfaceItemIdentifier, hasImage: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var constraints = [
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ]
        if hasImage {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.setContentHuggingPriority(.required, for: .horizontal)
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 20),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }
}

/// A sidebar of panes beside the selected pane, which a window and the previews show.
@MainActor
func makePaneSplitViewController(sidebar: SidebarViewController, detail: NSViewController) -> NSSplitViewController {
    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.minimumThickness = 180
    sidebarItem.maximumThickness = 320
    let detailItem = NSSplitViewItem(viewController: detail)
    detailItem.minimumThickness = 440
    let split = NSSplitViewController()
    split.addSplitViewItem(sidebarItem)
    split.addSplitViewItem(detailItem)
    return split
}

/// A window that shows one of several panes, chosen in its sidebar, and adds Macs from its toolbar.
@MainActor
final class PaneWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation {
    /// The command that pairs with a Mac. People also find it in the menu bar where the app has one.
    struct AddMac {
        let toolTip: String
        /// The choices, when the window can add more than one kind of Mac. Its delegate fills it when it opens.
        var menu: NSMenu?
        var isEnabled: @MainActor () -> Bool = { true }
        var perform: @MainActor () -> Void = {}
    }

    private static let addMacIdentifier = NSToolbarItem.Identifier("AddMac")
    private let addMac: AddMac

    /// - Parameters:
    ///   - split: The window's content, from `makePaneSplitViewController`.
    ///   - autosaveName: Names the window's saved frame and sidebar width.
    init(split: NSSplitViewController, autosaveName: String, addMac: AddMac) {
        self.addMac = addMac
        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        split.splitView.autosaveName = autosaveName
        let toolbar = NSToolbar(identifier: autosaveName)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.setContentSize(NSSize(width: 760, height: 620))
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.center()
        window.setFrameAutosaveName(autosaveName)
    }

    required init?(coder: NSCoder) { nil }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.addMacIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.addMacIdentifier else { return nil }
        let item: NSToolbarItem
        if let menu = addMac.menu {
            let menuItem = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            menuItem.menu = menu
            menuItem.showsIndicator = true
            item = menuItem
        } else {
            item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.target = self
            item.action = #selector(performAddMac(_:))
        }
        item.label = "Add Mac"
        item.toolTip = addMac.toolTip
        item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Mac")
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier != Self.addMacIdentifier || addMac.isEnabled()
    }

    @objc private func performAddMac(_ sender: Any?) { addMac.perform() }
}
