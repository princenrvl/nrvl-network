import AppKit
import NRVLCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Storage") {
                switch model.storage {
                case .opening:
                    Text("Opening database…")
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
                case .ready(let path, let entries, let broken):
                    LabeledContent("Database") {
                        Text(path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    LabeledContent("Audit log entries", value: "\(entries)")
                    LabeledContent("Audit chain") {
                        if let broken {
                            Label("Altered at entry \(broken)", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        } else {
                            Label("Intact", systemImage: "checkmark.seal").foregroundStyle(.green)
                        }
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
            }

            Section("Data labels") {
                ForEach([Confidence.confirmed, .inferred], id: \.self) { item in
                    LabeledContent { Text(item.explanation) } label: { item.badge }
                }
                ForEach([Freshness.live, .historical, .estimated], id: \.self) { item in
                    LabeledContent { Text(item.explanation) } label: { item.badge }
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build")
            }
        }
        .formStyle(.grouped)
    }
}
