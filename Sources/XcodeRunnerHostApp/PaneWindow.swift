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

/// What a window of panes shows: the panes that its sidebar lists, the one that is selected, and the window's title.
@MainActor
protocol PaneWindowModel: AnyObject, Observable {
    /// The panes that the sidebar lists, under their headings.
    var sidebarGroups: [SidebarGroup] { get }
    /// The pane that the window shows.
    var selectedPane: AnyHashable? { get }
    /// Shows the pane of the row that the person selected.
    func select(_ pane: AnyHashable)
    /// The name of the shown pane, which names the window.
    var title: String { get }
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

    private let model: any PaneWindowModel
    private let outline = NSOutlineView()
    private var shownGroups: [SidebarGroup]?
    private var nodes: [Node] = []
    /// Whether this controller changes the selection, which is then not the person's choice.
    private var isUpdating = false

    init(model: any PaneWindowModel) {
        self.model = model
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
            let groups = model.sidebarGroups
            let selection = model.selectedPane
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
        model.select(pane)
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

/// The detail side of a window: the view controller of the pane that is selected in the sidebar.
@MainActor
final class PaneContainerViewController: NSViewController {
    override func loadView() { view = NSView() }

    /// Shows a pane in place of the one shown before.
    func show(_ pane: NSViewController) {
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(pane)
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pane.view.topAnchor.constraint(equalTo: view.topAnchor),
            pane.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

/// A window's content: a sidebar of panes beside the selected pane. It gives its window the toolbar that hides the
/// sidebar, so that every window that shows it has one, a preview's window included.
///
/// A subclass makes the view controllers of its window's panes and pairs with Macs.
@MainActor
class PaneSplitViewController: NSSplitViewController, NSToolbarDelegate {
    private let windowModel: any PaneWindowModel
    private let detail = PaneContainerViewController()
    private let autosaveName: String
    /// The pane that `detail` shows. Nothing is shown before the view loads.
    private var shownPane: AnyHashable??

    /// - Parameter autosaveName: Names the saved sidebar width and the toolbar.
    init(model: any PaneWindowModel, autosaveName: String) {
        windowModel = model
        self.autosaveName = autosaveName
        super.init(nibName: nil, bundle: nil)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: SidebarViewController(model: model))
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 400
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        // The size of a window that opens for the first time, and of a preview's window.
        preferredContentSize = NSSize(width: 760, height: 620)
    }

    required init?(coder: NSCoder) { nil }

    /// Makes the view controller of the pane that the window's model has selected.
    func makePaneViewController() -> NSViewController { NSViewController() }

    /// Shows the selected pane and names the window after it, then waits for either to change.
    private func update() {
        let (pane, title) = withObservationTracking {
            (windowModel.selectedPane, windowModel.title)
        } onChange: { [weak self] in
            Task { @MainActor in self?.update() }
        }
        self.title = title
        guard pane != shownPane else { return }
        shownPane = pane
        detail.show(makePaneViewController())
    }

    /// Whether the sheet that pairs with a Mac is open. One sheet pairs at a time.
    var isAddingMac: Bool { presentedViewControllers?.contains { $0 is AddMacViewController } == true }

    /// Opens the sheet that pairs with a Mac for `macs`.
    ///
    /// - Parameter paired: Called with the Mac after the sheet closed, unless the person cancelled.
    func presentAddMacSheet(for macs: any MacList, paired: @escaping @MainActor (ListedMac) -> Void) {
        let model = AddMacModel(macs: macs)
        let sheet = AddMacViewController(model: model)
        model.onFinish = { [weak self, weak sheet] mac in
            if let sheet { self?.dismiss(sheet) }
            if let mac { paired(mac) }
        }
        presentAsSheet(sheet)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = autosaveName
        update()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard let window = view.window, window.toolbar?.delegate !== self else { return }
        let toolbar = NSToolbar(identifier: autosaveName)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}

/// Creates a window for panes, which keeps its frame under `autosaveName`.
@MainActor
func makePaneWindowController(content: PaneSplitViewController, autosaveName: String) -> NSWindowController {
    let window = NSWindow(contentViewController: content)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.contentMinSize = NSSize(width: 640, height: 420)
    window.center()
    window.setFrameAutosaveName(autosaveName)
    return NSWindowController(window: window)
}
