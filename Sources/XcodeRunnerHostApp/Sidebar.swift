import AppKit
import Observation

/// A pane that a window's sidebar lists.
struct SidebarRow: Equatable {
    enum Icon: Equatable {
        case symbol(String)
        /// An image in the app's resources that is drawn in the sidebar's color, as symbols are.
        case template(String)
    }

    /// How the pane's Mac is doing, as a symbol at the row's trailing edge. The subtitle says the same in words.
    struct Status: Equatable {
        let symbol: String
        let color: NSColor
    }

    /// The pane that the window shows while the row is selected.
    let pane: AnyHashable
    let title: String
    /// A few words under the title, such as a Mac's state or the account that is signed in.
    var subtitle: String?
    let icon: Icon
    var status: Status?
}

/// Rows of a sidebar under one heading, or at its top without one.
struct SidebarGroup: Equatable {
    let title: String?
    let rows: [SidebarRow]
}

/// The sidebar of a window: an outline of the panes that the window can show, under headings that stay at the top
/// while their rows scroll.
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
        outline.intercellSpacing = NSSize(width: 0, height: 2)
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
                show(groups)
                shownGroups = groups
            }
            let row = (nodes + nodes.flatMap(\.children)).first { $0.row?.pane == selection }.map(outline.row(forItem:)) ?? -1
            if row != outline.selectedRow {
                outline.selectRowIndexes(row < 0 ? [] : [row], byExtendingSelection: false)
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.update() }
        }
    }

    /// Lists `groups`. Rows whose panes stay keep their views and take the new words, so that a state that changes
    /// does not redraw the list.
    private func show(_ groups: [SidebarGroup]) {
        let rows = groups.flatMap(\.rows)
        let shownRows = shownGroups?.flatMap(\.rows) ?? []
        guard groups.map(\.title) == shownGroups?.map(\.title), rows.map(\.pane) == shownRows.map(\.pane) else {
            nodes = groups.flatMap { group in
                let rows = group.rows.map { Node(row: $0) }
                return group.title.map { [Node(heading: $0, children: rows)] } ?? rows
            }
            outline.reloadData()
            outline.expandItem(nil, expandChildren: true)
            return
        }
        for row in rows {
            let index = outline.row(forItem: (nodes + nodes.flatMap(\.children)).first { $0.row?.pane == row.pane })
            (outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarCellView)?.show(row)
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

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? Node)?.heading == nil ? 40 : 26
    }

    // Every group stays open: a window lists a few panes, and a closed group would hide the selected one.
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if let heading = node.heading {
            let identifier = NSUserInterfaceItemIdentifier("Heading")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? Self.makeHeadingCell()
            cell.identifier = identifier
            cell.textField?.stringValue = heading
            return cell
        }
        guard let row = node.row else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("Row")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView ?? SidebarCellView()
        cell.identifier = identifier
        cell.show(row)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdating, let pane = (outline.item(atRow: outline.selectedRow) as? Node)?.row?.pane else { return }
        model.select(pane)
    }

    private static func makeHeadingCell() -> NSTableCellView {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        text.textColor = .secondaryLabelColor
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// A row of the sidebar: a pane's icon, its title above a few words about it, and a symbol for its Mac's state.
@MainActor
private final class SidebarCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let status = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The table gives its image and text views the sidebar's colors, also in a selected row.
        imageView = icon
        textField = title
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        icon.imageScaling = .scaleProportionallyDown
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        status.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        for view in [icon, labels, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(lessThanOrEqualToConstant: 24),
            icon.heightAnchor.constraint(lessThanOrEqualToConstant: 24),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -6),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ row: SidebarRow) {
        title.stringValue = row.title
        subtitle.stringValue = row.subtitle ?? ""
        subtitle.isHidden = row.subtitle == nil
        switch row.icon {
        case .symbol(let name): icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .template(let name):
            let image = Bundle.module.image(forResource: name)
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            icon.image = image
        }
        status.image = row.status.flatMap { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) }
        status.contentTintColor = row.status?.color
        status.isHidden = row.status == nil
        setAccessibilityLabel([row.title, row.subtitle].compactMap { $0 }.joined(separator: ", "))
    }
}
