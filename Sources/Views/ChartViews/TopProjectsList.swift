import SwiftUI

/// List of top projects sorted by token consumption.
struct TopProjectsList: View {
    let projects: [(name: String, tokens: Int)]
    var accentColor: Color = Color(hex: 0xd4a843)

    var body: some View {
        if projects.isEmpty {
            Text("No project data")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            VStack(spacing: 4) {
                ForEach(projects.prefix(5), id: \.name) { project in
                    HStack {
                        Text(project.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(formatCompactTokens(project.tokens))
                            .font(.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}
