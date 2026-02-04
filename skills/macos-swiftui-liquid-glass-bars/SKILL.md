---
name: macos-swiftui-liquid-glass-bars
description: Enforce Apple-style “Liquid Glass” rules for macOS SwiftUI navigation layers (toolbar/sidebar/tab bar/menus). Use when designing or refactoring UI so glass stays in navigation/controls (not content), avoids glass-on-glass, defaults to a single variant (Regular vs Clear; never mixed), adds a dimming layer if Clear is used, groups toolbar items by task, and stays readable under Reduced Transparency/ Increased Contrast/ Reduced Motion.
---

# macOS SwiftUI Liquid Glass Bars

## Goal

Design “Liquid Glass” bars as a navigation/controls layer that floats above content, stays clean and readable, and remains robust under accessibility settings.

## Ask For Context (minimum)

- What are your navigation surfaces: `NavigationSplitView` sidebar, toolbar, tab bar, menus, custom top bar?
- What is content: lists/tables, lyrics, album art, detail panels, cards?
- Where are you currently applying translucent materials or custom backgrounds?
- Do you need **Clear** glass anywhere, or can everything be **Regular**?

## Hard Constraints (treat as non-negotiable)

1. **Glass = navigation/controls; Content = content.**
2. **Avoid glass-on-glass.** Never stack a glass surface on another glass surface.
3. **Pick one variant for the app surface: Regular or Clear. Never mix.**
4. **Default to Regular.** Use Clear only if you will add a **dimming layer** (scrim) for readability.
5. **Group toolbar items by task** (primary actions, secondary actions, view/layout toggles). Avoid a “misc icon row”.
6. **Keep bars floating above content** as content scrolls; preserve separation and readability.
7. **Pass accessibility toggles**: Reduced Transparency, Increased Contrast, Reduced Motion, Light/Dark.

## Workflow (apply in this order)

1. **Classify layers**
   - Navigation layer: sidebar, toolbar, tab bar, menus, play controls.
   - Content layer: lists/tables, lyrics, album artwork, library grids, detail content.
2. **Remove glass from content**
   - Remove any “glass card” styling from content lists/tables/cards.
   - Keep content surfaces visually solid/legible.
3. **Use system bars first**
   - Prefer `NavigationSplitView`, system `toolbar`, system sidebar `List` so the system can apply the latest bar appearance automatically.
4. **Implement toolbar grouping**
   - Use `ToolbarItemGroup` for each task group; make primary actions visually prominent without tinting everything.
5. **Only if using Clear: add a dimming layer**
   - Add a thin scrim behind bar content (not a second glass surface).
6. **Verify in edge cases**
   - Test on busy backgrounds (album art), Light/Dark, and the accessibility settings listed above.

## SwiftUI Skeleton (macOS)

Use this as a base. Add detail views and content styling without turning content into glass.

```swift
import SwiftUI

struct RootView: View {
    @State private var selection: SidebarItem? = .library

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Library", systemImage: "music.note.list").tag(SidebarItem.library)
                Label("Playlists", systemImage: "rectangle.stack").tag(SidebarItem.playlists)
                Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
            }
            .navigationTitle("My Player")
        } content: {
            ContentView(selection: selection)
                .navigationTitle(selection?.title ?? "")
        } detail: {
            DetailView()
        }
        .toolbar {
            // Primary tasks
            ToolbarItemGroup {
                Button { /* play */ } label: { Image(systemName: "play.fill") }
                Button { /* pause */ } label: { Image(systemName: "pause.fill") }
            }

            // Secondary tasks
            ToolbarItemGroup {
                Button { /* search */ } label: { Image(systemName: "magnifyingglass") }
                Button { /* add */ } label: { Image(systemName: "plus") }
            }

            // View/layout
            ToolbarItemGroup {
                Button { /* toggle sidebar */ } label: { Image(systemName: "sidebar.left") }
            }
        }
    }

    enum SidebarItem: Hashable {
        case library, playlists, settings
        var title: String {
            switch self {
            case .library: return "Library"
            case .playlists: return "Playlists"
            case .settings: return "Settings"
            }
        }
    }
}

struct ContentView: View {
    let selection: RootView.SidebarItem?
    var body: some View {
        // Content layer: keep it “content-like”; do not apply glass materials broadly here.
        List(0..<50, id: \.self) { i in
            Text("Row \(i)")
        }
    }
}

struct DetailView: View {
    var body: some View {
        Text("Detail")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

## Readability / Accessibility Checklist

Validate every bar surface against:

- Light + Dark mode
- Busy content (e.g., high-contrast album art behind the bar)
- Reduced Transparency
- Increased Contrast
- Reduced Motion

## Anti-patterns (reject these)

- Turning the main list/table surface into glass.
- Glass card UI placed on top of a glass toolbar/sidebar (glass-on-glass).
- Tinting every toolbar icon to “make it pop” (creates visual noise; prefer emphasis only on primary actions).

## References

Load `references/liquid-glass-bars-rules.md` for the full ruleset and copy/pasteable “hard constraints”.
