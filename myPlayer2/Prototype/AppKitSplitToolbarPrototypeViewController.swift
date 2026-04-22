//
//  AppKitSplitToolbarPrototypeViewController.swift
//  myPlayer2
//
//  Minimal three-column NSSplitViewController used to validate toolbar tracking.
//

import AppKit
import SwiftUI

@MainActor
final class AppKitSplitToolbarPrototypeViewController: NSSplitViewController {
    static let mainLyricsDividerIndex = 1

    private let sidebarItem: NSSplitViewItem
    private let mainItem: NSSplitViewItem
    private let lyricsItem: NSSplitViewItem
    private var didApplyInitialLayout = false
    private var isShowingWideLyrics = false

    init() {
        let sidebarController = NSHostingController(
            rootView: AppKitSplitToolbarPrototypeSidebarContent()
        )
        sidebarController.title = "sidebar"

        let mainController = NSHostingController(
            rootView: AppKitSplitToolbarPrototypeMainContent()
        )
        mainController.title = "main"

        let lyricsController = NSHostingController(
            rootView: AppKitSplitToolbarPrototypeLyricsContent()
        )
        lyricsController.title = "lyrics"

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = true
        sidebarItem.preferredThicknessFraction = 0.18

        let mainItem = NSSplitViewItem(viewController: mainController)
        mainItem.minimumThickness = 420
        mainItem.canCollapse = false

        let lyricsItem = NSSplitViewItem(inspectorWithViewController: lyricsController)
        lyricsItem.minimumThickness = 260
        lyricsItem.maximumThickness = 460
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
        splitView.autosaveName = "AppKitSplitToolbarPrototypeSplitView"
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        guard !didApplyInitialLayout else { return }
        didApplyInitialLayout = true

        splitView.setPosition(220, ofDividerAt: 0)
        splitView.setPosition(splitView.bounds.width - 320, ofDividerAt: Self.mainLyricsDividerIndex)
        splitView.adjustSubviews()

        print("[PrototypeSplit] \(runtimeVerificationSnapshot())")
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

    func setLyricsPaneWidth(_ targetLyricsWidth: CGFloat) {
        splitView.setPosition(
            splitView.bounds.width - targetLyricsWidth,
            ofDividerAt: Self.mainLyricsDividerIndex
        )
        splitView.adjustSubviews()
        print("[PrototypeSplit] lyricsWidth=\(Int(targetLyricsWidth))")
    }

    func toggleMainLyricsDividerPosition() {
        isShowingWideLyrics.toggle()
        setLyricsPaneWidth(isShowingWideLyrics ? 420 : 300)
    }
}
