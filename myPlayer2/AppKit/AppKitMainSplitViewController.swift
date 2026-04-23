//
//  AppKitMainSplitViewController.swift
//  myPlayer2
//
//  AppKit-driven three-column split that mirrors sidebar/lyrics visibility + widths
//  into UIStateViewModel (AppKit is source of truth; UIState is persistence/mirror).
//

import AppKit
import SwiftUI

@MainActor
final class AppKitMainSplitViewController: NSSplitViewController {
    static let mainLyricsDividerIndex = 1

    private let appSession: AppSessionHost
    private let sidebarItem: NSSplitViewItem
    private let mainItem: NSSplitViewItem
    private let lyricsItem: NSSplitViewItem

    private var didApplyInitialLayout = false
    private var lastMirroredSidebarWidth: CGFloat = -1
    private var lastMirroredLyricsWidth: CGFloat = -1

    init(appSession: AppSessionHost) {
        self.appSession = appSession

        let sidebarController = NSHostingController(
            rootView: AppKitMainSidebarPaneRoot(appSession: appSession)
        )
        sidebarController.title = "sidebar"

        let mainController = NSHostingController(
            rootView: AppKitMainContentPaneRoot(appSession: appSession)
        )
        mainController.title = "main"

        let lyricsController = NSHostingController(
            rootView: AppKitMainLyricsPaneRoot(appSession: appSession)
        )
        lyricsController.title = "lyrics"

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = Constants.Layout.sidebarMinWidth
        sidebarItem.maximumThickness = Constants.Layout.sidebarMaxWidth
        sidebarItem.canCollapse = true
        sidebarItem.preferredThicknessFraction = 0.18

        let mainItem = NSSplitViewItem(viewController: mainController)
        mainItem.minimumThickness = Constants.Layout.detailContentMinWidth
        mainItem.canCollapse = false

        let lyricsItem = NSSplitViewItem(inspectorWithViewController: lyricsController)
        lyricsItem.minimumThickness = Constants.Layout.lyricsPanelMinWidth
        lyricsItem.maximumThickness = Constants.Layout.lyricsPanelMaxWidth
        lyricsItem.canCollapse = true
        lyricsItem.preferredThicknessFraction = 0.28

        self.sidebarItem = sidebarItem
        self.mainItem = mainItem
        self.lyricsItem = lyricsItem

        super.init(nibName: nil, bundle: nil)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(mainItem)
        addSplitViewItem(lyricsItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .paneSplitter
        splitView.autosaveName = "AppKitMainSplitView"
        splitView.delegate = self
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        guard !didApplyInitialLayout else { return }
        didApplyInitialLayout = true

        applyInitialLayoutFromMirroredState()
        mirrorSplitStateToUIState(reason: "initial")

        print("[AppKitMainSplit] \(runtimeVerificationSnapshot())")
    }

    func runtimeVerificationSnapshot() -> String {
        let order = splitViewItems.map { item in
            let title = item.viewController.title ?? "untitled"
            return title.isEmpty ? "untitled" : title
        }

        return [
            "root=\(type(of: self))",
            "items=\(splitViewItems.count)",
            "order=\(order.joined(separator: ","))",
            "dividerCount=\(max(splitViewItems.count - 1, 0))",
            "dividerIndex(main|lyrics)=\(Self.mainLyricsDividerIndex)"
        ].joined(separator: " ")
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        mirrorSplitStateToUIState(reason: "resize")
    }

    private func applyInitialLayoutFromMirroredState() {
        let uiState = appSession.uiState

        sidebarItem.isCollapsed = !uiState.sidebarVisible
        lyricsItem.isCollapsed = !uiState.lyricsVisible

        if !sidebarItem.isCollapsed {
            let sidebarWidth = clampOrDefault(
                uiState.sidebarLastWidth,
                defaultValue: Constants.Layout.sidebarDefaultWidth,
                min: Constants.Layout.sidebarMinWidth,
                max: Constants.Layout.sidebarMaxWidth
            )
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        }

        if !lyricsItem.isCollapsed {
            let sidebarWidth: CGFloat = sidebarItem.isCollapsed
                ? 0
                : (sidebarItem.viewController.view.frame.width)

            let maxLyricsGivenWindow = splitView.bounds.width
                - sidebarWidth
                - mainItem.minimumThickness

            let clampedMaxLyrics = Swift.max(
                Constants.Layout.lyricsPanelMinWidth,
                Swift.min(Constants.Layout.lyricsPanelMaxWidth, maxLyricsGivenWindow)
            )

            let lyricsWidth = clampOrDefault(
                uiState.lyricsWidth,
                defaultValue: Constants.Layout.lyricsPanelDefaultWidth,
                min: Constants.Layout.lyricsPanelMinWidth,
                max: clampedMaxLyrics
            )
            splitView.setPosition(splitView.bounds.width - lyricsWidth, ofDividerAt: Self.mainLyricsDividerIndex)
        }

        splitView.adjustSubviews()
    }

    private func mirrorSplitStateToUIState(reason: String) {
        let uiState = appSession.uiState

        let sidebarVisible = !sidebarItem.isCollapsed
        let lyricsVisible = !lyricsItem.isCollapsed
        if uiState.sidebarVisible != sidebarVisible {
            uiState.sidebarVisible = sidebarVisible
        }
        if uiState.lyricsVisible != lyricsVisible {
            uiState.lyricsVisible = lyricsVisible
        }

        if sidebarVisible {
            let width = sidebarItem.viewController.view.frame.width
            if abs(width - lastMirroredSidebarWidth) > 0.5 {
                lastMirroredSidebarWidth = width
                uiState.sidebarLastWidth = width
            }
        }

        if lyricsVisible {
            let width = lyricsItem.viewController.view.frame.width
            if abs(width - lastMirroredLyricsWidth) > 0.5 {
                lastMirroredLyricsWidth = width
                uiState.lyricsWidth = width
            }
        }

        print("[AppKitMainSplit] mirror reason=\(reason) sidebarVisible=\(sidebarVisible) lyricsVisible=\(lyricsVisible) sidebarWidth=\(Int(lastMirroredSidebarWidth)) lyricsWidth=\(Int(lastMirroredLyricsWidth))")
    }

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, min), max)
    }

    private func clampOrDefault(
        _ value: CGFloat,
        defaultValue: CGFloat,
        min: CGFloat,
        max: CGFloat
    ) -> CGFloat {
        let resolved = value > 0 ? value : defaultValue
        return clamp(resolved, min: min, max: max)
    }
}
