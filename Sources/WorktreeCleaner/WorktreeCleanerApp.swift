import SwiftUI
import AppKit
import WorktreeCleanerCore

@main
struct WorktreeCleanerApp: App {
    @State private var state = AppState()

    var body: some Scene {
        Window("Worktree Cleaner", id: "main") {
            MainWindowView(state: state)
                .frame(minWidth: 820, minHeight: 540)
                .task {
                    if state.items.isEmpty {
                        await state.refresh()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 940, height: 620)

        MenuBarExtra {
            MenuBarView(state: state)
                .task {
                    if state.items.isEmpty {
                        await state.refresh()
                    }
                }
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: MenuBarIconRenderer.templateImage)
                if !state.safeItems.isEmpty {
                    Text("\(state.safeItems.count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
