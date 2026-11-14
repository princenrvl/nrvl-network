import SwiftUI

@main
struct NRVLNetworkApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // Single window: the sidebar selection and inventory are app-wide state.
        Window("NRVL Network", id: "main") {
            RootView(model: model)
                .frame(minWidth: 860, minHeight: 540)
                .preferredColorScheme(.dark)
                .tint(.nrvlAccent)
                .task { await model.start() }
        }
        .commands {
            CommandMenu("Go") {
                ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
                    let button = Button(section.title) { model.selection = section }
                    // ⌘1–⌘9 for the first nine; Settings also has the standard ⌘, window.
                    if index < 9 {
                        button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    } else {
                        button
                    }
                }
            }
        }

        Settings {
            SettingsView(model: model)
                .frame(width: 560, height: 460)
                .preferredColorScheme(.dark)
                .task { await model.start() }
        }
    }
}
