import AppKit
import Observation
import SwiftUI

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
    /// Whether a save from the pane runs now.
    var isSaving: Bool { get }
    /// How many of the values of the running save are saved, and how many it saves in all.
    var saveProgress: (completed: Int, total: Int) { get }
    /// Whether a value in the pane differs from the saved one.
    var hasEdits: Bool { get }
    /// Shows the saved values again in place of the edited ones.
    func revert()
    /// Saves those values. Each value that could not be saved shows why in the pane.
    func save()
}

/// A thin bar under the toolbar that fills while the shown pane saves, as a browser's does while a page loads. A save
/// does not tell how far a value is, so the bar moves on by itself within each value and jumps when one is saved.
private struct SaveProgressBar: View {
    let saving: (any PaneSaving)?
    /// When the save that the bar shows began. `nil` hides the bar.
    @State private var startedAt: Date?
    /// Whether the save ended, so that the bar fills before it fades.
    @State private var isComplete = false

    var body: some View {
        let isSaving = saving?.isSaving == true
        TimelineView(.animation(paused: startedAt == nil || isComplete)) { timeline in
            GeometryReader { geometry in
                Capsule()
                    .fill(.tint)
                    .frame(width: geometry.size.width * fraction(at: timeline.date))
                    .animation(.easeOut(duration: 0.25), value: saving?.saveProgress.completed)
                    .animation(.easeOut(duration: 0.25), value: isComplete)
            }
        }
        .frame(height: 3)
        .opacity(startedAt == nil ? 0 : 1)
        .accessibilityHidden(true)
        .onChange(of: isSaving, initial: true) { _, isSaving in
            if isSaving {
                isComplete = false
                startedAt = .now
            } else if startedAt != nil {
                isComplete = true
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    // A save that began meanwhile keeps its bar.
                    if isComplete { withAnimation(.easeOut(duration: 0.3)) { startedAt = nil } }
                }
            }
        }
    }

    private func fraction(at date: Date) -> Double {
        guard let startedAt, let saving else { return 0 }
        if isComplete { return 1 }
        let progress = saving.saveProgress
        let total = Double(max(progress.total, 1))
        // Within the value being saved the bar nears its end without reaching it.
        let within = 0.9 * (1 - exp(-date.timeIntervalSince(startedAt) / 3))
        return min((Double(progress.completed) + within) / total, 1)
    }
}

/// The toolbar's Save button, which a progress indicator replaces while the shown pane saves.
private struct SaveToolbarButton: View {
    /// The shown pane's values, when it has any to save.
    let saving: (any PaneSaving)?

    var body: some View {
        let isSaving = saving?.isSaving == true
        ZStack {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Saving")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            } else {
                Button("Save") { saving?.save() }
                    // The toolbar item draws the button's shape, tinted while there is a value to save.
                    .buttonStyle(.borderless)
                    .disabled(saving?.canSave != true)
                    // The host's own window has no menu bar, so the button takes the shortcut itself.
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Save the changes in this pane")
                    .accessibilityIdentifier("save-pane")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.default, value: isSaving)
    }
}

/// A pane's view controller whose pane has values to save.
@MainActor
protocol SavingPaneViewController: NSViewController {
    var saving: any PaneSaving { get }
}

/// The detail side of a window: the view controller of the pane that is selected in the sidebar.
@MainActor
final class PaneContainerViewController: NSViewController {
    private let progressBar = NSHostingView(rootView: SaveProgressBar(saving: nil))

    override func loadView() {
        view = NSView()
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
    }

    /// Shows a pane in place of the one shown before, with the progress of its saves under the toolbar.
    func show(_ pane: NSViewController) {
        progressBar.rootView = SaveProgressBar(saving: (pane as? any SavingPaneViewController)?.saving)
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(pane)
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pane.view, positioned: .below, relativeTo: progressBar)
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
class PaneSplitViewController: NSSplitViewController, NSToolbarDelegate, NSMenuItemValidation {
    private let windowModel: any PaneWindowModel
    private let detail = PaneContainerViewController()
    private let autosaveName: String
    /// The pane that `detail` shows. Nothing is shown before the view loads.
    private var shownPane: AnyHashable??
    /// What the toolbar's Save button saves: the shown pane's values, when it has any.
    private var saving: (any PaneSaving)?
    /// The view controllers of panes that were left while they saved. A pane that is shown again before its save
    /// ended is the same one, so that the values still to save take no edits.
    private var panesLeftSaving: [AnyHashable?: NSViewController] = [:]
    private let saveItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("save"))
    private let saveButton = NSHostingView(rootView: SaveToolbarButton(saving: nil))
    /// Drops the shown pane's edits. The toolbar shows it only while the pane has any.
    private let revertItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("revert"))

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
        if let shown = shownPane, let left = detail.children.first, saving?.isSaving == true {
            panesLeftSaving[shown] = left
        }
        panesLeftSaving = panesLeftSaving.filter { ($0.value as? any SavingPaneViewController)?.saving.isSaving == true }
        shownPane = pane
        let controller = panesLeftSaving.removeValue(forKey: pane) ?? makePaneViewController()
        detail.show(controller)
        saving = (controller as? any SavingPaneViewController)?.saving
        saveButton.rootView = SaveToolbarButton(saving: saving)
        updateSaveItemStyle()
    }

    /// Tints the toolbar's Save while the shown pane has a value to save and shows Revert while it has edits, then
    /// waits for either to change.
    private func updateSaveItemStyle() {
        guard let saving else {
            saveItem.style = .plain
            revertItem.isHidden = true
            return
        }
        let watched = ObjectIdentifier(saving)
        let (canSave, canRevert) = withObservationTracking {
            (saving.canSave, saving.hasEdits && !saving.isSaving)
        } onChange: { [weak self] in
            Task { @MainActor in
                // A pane that was replaced since is no longer watched.
                if let self, self.saving.map(ObjectIdentifier.init) == watched { self.updateSaveItemStyle() }
            }
        }
        saveItem.style = canSave ? .prominent : .plain
        revertItem.isHidden = !canRevert
    }

    /// Saves the shown pane's edited values, for the File menu's Save command.
    @objc func savePane(_ sender: Any?) { saving?.save() }

    @objc private func revertPane(_ sender: Any?) {
        guard let saving, !saving.isSaving else { return }
        saving.revert()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(savePane) ? saving?.canSave == true : true
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
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, revertItem.itemIdentifier, saveItem.itemIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == revertItem.itemIdentifier {
            revertItem.label = "Revert"
            revertItem.title = "Revert"
            revertItem.toolTip = "Show the saved values again"
            revertItem.isBordered = true
            // The shown pane shows and hides the item. Validation would ask the responder chain.
            revertItem.autovalidates = false
            revertItem.target = self
            revertItem.action = #selector(revertPane)
            return revertItem
        }
        guard itemIdentifier == saveItem.itemIdentifier else { return nil }
        saveItem.label = "Save"
        saveItem.view = saveButton
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
