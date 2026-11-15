import AppKit
import Observation

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

/// What a pane saves when the person chooses Save in the window's toolbar: the values that were edited in it.
@MainActor
protocol PaneSaving: AnyObject, Observable {
    /// Whether the pane has a value to save now: an edited one, or one whose last save failed.
    var canSave: Bool { get }
    /// Saves those values. Each value that could not be saved shows why in the pane.
    func save()
}

/// A pane's view controller whose pane has values to save.
@MainActor
protocol SavingPaneViewController: NSViewController {
    var saving: any PaneSaving { get }
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
    /// What the toolbar's Save button saves: the shown pane's values, when it has any.
    private var saving: (any PaneSaving)?
    private let saveItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("save"))

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
        let controller = makePaneViewController()
        detail.show(controller)
        saving = (controller as? any SavingPaneViewController)?.saving
        updateSaveItem()
    }

    /// Enables Save while the shown pane has a value to save, then waits for that to change.
    private func updateSaveItem() {
        guard let saving else {
            saveItem.isEnabled = false
            return
        }
        let watched = ObjectIdentifier(saving)
        saveItem.isEnabled = withObservationTracking {
            saving.canSave
        } onChange: { [weak self] in
            Task { @MainActor in
                // A pane that was replaced since is no longer watched.
                if let self, self.saving.map(ObjectIdentifier.init) == watched { self.updateSaveItem() }
            }
        }
    }

    @objc private func savePane(_ sender: Any?) { saving?.save() }

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
        // The size of a window that opens for the first time, and of a preview's window. A preferred content size
        // would keep the window at that size.
        view.setFrameSize(NSSize(width: 760, height: 620))
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
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, saveItem.itemIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == saveItem.itemIdentifier else { return nil }
        saveItem.label = "Save"
        saveItem.title = "Save"
        saveItem.toolTip = "Save the changes in this pane"
        saveItem.isBordered = true
        saveItem.style = .prominent
        // The shown pane enables the item. Validation would ask the responder chain, which has no such action.
        saveItem.autovalidates = false
        saveItem.target = self
        saveItem.action = #selector(savePane)
        return saveItem
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
