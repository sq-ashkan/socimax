import SwiftUI
import SwiftData

struct SourceListView: View {
    let sources: [Source]
    @Environment(\.modelContext) private var modelContext
    @State private var newURL = ""

    var project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add source URL...", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addSource() }
                Button("Add", action: addSource)
                    .disabled(newURL.isEmpty)
            }

            List {
                ForEach(sources.sorted(by: { $0.createdAt < $1.createdAt })) { source in
                    HStack {
                        Image(systemName: "globe")
                        VStack(alignment: .leading) {
                            Text(source.name)
                            Text(source.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(source.articles.count) articles")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let sorted = sources.sorted(by: { $0.createdAt < $1.createdAt })
                    for index in offsets {
                        modelContext.delete(sorted[index])
                    }
                }
            }
        }
    }

    private func addSource() {
        let url = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let normalizedURL = url.hasPrefix("http") ? url : "https://\(url)"
        let source = Source(url: normalizedURL)
        source.project = project
        modelContext.insert(source)
        newURL = ""
    }
}
