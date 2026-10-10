import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarWidth: CGFloat = 240
    @GestureState private var sidebarDrag: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            workspace
                .toolbar {
                    if #available(macOS 26.0, *) {
                        sidebarToggle.sharedBackgroundVisibility(.hidden)
                        if !store.isSidebarVisible {
                            libraryTabs(width: geometry.size.width - 170)
                                .sharedBackgroundVisibility(.hidden)
                        }
                    } else {
                        sidebarToggle
                        if !store.isSidebarVisible {
                            libraryTabs(width: geometry.size.width - 170)
                        }
                    }
                }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        // .task runs after first render — safe place to do @Published mutations
        .task {
            store.bootstrap()
        }
    }

    private var workspace: some View {
        let expandedSidebarWidth = min(320, max(200, sidebarWidth + sidebarDrag))
        let panelCornerRadius: CGFloat = store.isSidebarVisible ? 14 : 0
        return HStack(spacing: 0) {
            SidebarView()
                .frame(width: expandedSidebarWidth)
                .frame(width: store.isSidebarVisible ? expandedSidebarWidth : 0, alignment: .leading)
                .clipped()
                .opacity(store.isSidebarVisible ? 1 : 0)
                .allowsHitTesting(store.isSidebarVisible)
                .accessibilityHidden(!store.isSidebarVisible)
                .overlay(alignment: .trailing) {
                    if store.isSidebarVisible {
                        Color.clear
                            .frame(width: 6)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(coordinateSpace: .global)
                                .updating($sidebarDrag) { value, offset, _ in offset = value.translation.width }
                                .onEnded { resizeSidebar(by: $0.translation.width) })
                            .accessibilityLabel("Sidebar width")
                            .accessibilityValue("\(Int(sidebarWidth)) points")
                            .accessibilityAdjustableAction { direction in
                                switch direction {
                                case .increment: resizeSidebar(by: 20)
                                case .decrement: resizeSidebar(by: -20)
                                @unknown default: break
                                }
                            }
                    }
                }

            VStack(spacing: 0) {
                MainView()
                GlobalPlaybackBar()
            }
            .background(AppTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: panelCornerRadius)
                    .strokeBorder(AppTheme.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            .padding(store.isSidebarVisible ? 8 : 0)
            .ignoresSafeArea(.container, edges: store.isSidebarVisible ? .top : [])
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.isSidebarVisible)
        .background(AppTheme.chrome)
        .disabled(!store.canUseLibrary)
        .overlay(alignment: .top) {
            if store.isShuttingDown {
                ProgressView("Finishing background work…").padding().background(.regularMaterial)
            } else if store.isLibraryChanging {
                ProgressView("Updating library…").padding().background(.regularMaterial)
            } else if !store.isReady && !store.isShuttingDown {
                VStack(spacing: 8) {
                    if let error = store.lastBackendError {
                        Text(error)
                        Button("Retry opening library") { store.bootstrap() }
                    } else {
                        ProgressView("Opening library…")
                    }
                }
                .padding()
                .background(.regularMaterial)
            }
        }
    }

    private func libraryTabs(width: CGFloat) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            LibraryTabsView()
                // Leave room for the traffic lights, sidebar toggle, and toolbar margins.
                .frame(width: max(0, width), height: 34)
                .disabled(!store.canUseLibrary)
        }
    }

    private func resizeSidebar(by delta: CGFloat) {
        sidebarWidth = min(320, max(200, sidebarWidth + delta))
    }

    private var sidebarToggle: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                store.isSidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isSidebarVisible ? "Collapse Sidebar" : "Show Sidebar")
            .help(store.isSidebarVisible ? "Collapse sidebar" : "Show sidebar")
        }
    }
}
