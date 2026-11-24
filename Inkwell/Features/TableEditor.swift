import InkwellKit
import SwiftUI

/// A Markdown table as a grid: type in cells, add, move and remove rows and columns, set each column's alignment.
/// The table goes back into the post as aligned Markdown in one undo step.
struct TableEditorSheet: View {
    var model: AppModel
    let edit: AppModel.TableEdit
    @State private var table: MarkdownTable
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, edit: AppModel.TableEdit) {
        self.model = model
        self.edit = edit
        _table = State(initialValue: edit.table)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(edit.range == nil ? "Insert a table" : "Edit table").font(.title2.weight(.semibold))
                Spacer()
                Text("\(table.columnCount) columns · \(table.rows.count) rows")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Color.clear.frame(width: 24, height: 1)
                        ForEach(0 ..< table.columnCount, id: \.self) { c in columnMenu(c) }
                    }
                    GridRow {
                        Color.clear.frame(width: 24, height: 1)
                        ForEach(0 ..< table.columnCount, id: \.self) { c in
                            cell(text(row: nil, column: c), column: c, prompt: String(localized: "Heading")).fontWeight(.semibold)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(table.rows.indices, id: \.self) { r in
                        GridRow {
                            rowMenu(r)
                            ForEach(0 ..< table.columnCount, id: \.self) { c in cell(text(row: r, column: c), column: c, prompt: "") }
                        }
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 160, maxHeight: 420)
            HStack {
                Button("Add Row", systemImage: "plus") { table.insertRow(at: table.rows.count) }
                Button("Add Column", systemImage: "plus") { table.insertColumn(at: table.columnCount) }
                Spacer()
                Button("Cancel") {
                    model.tableEdit = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(edit.range == nil ? "Insert Table" : "Update Table") {
                    model.finishTableEdit(table)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: min(1000, CGFloat(table.columnCount) * 170 + 90), maxWidth: 1100)
    }

    /// Bindings that ignore an index a just-deleted row or column left behind.
    func text(row: Int?, column c: Int) -> Binding<String> {
        Binding(get: {
            guard let r = row else { return table.header.indices.contains(c) ? table.header[c] : "" }
            return table.rows.indices.contains(r) && table.rows[r].indices.contains(c) ? table.rows[r][c] : ""
        }, set: { value in
            if let r = row {
                if table.rows.indices.contains(r), table.rows[r].indices.contains(c) { table.rows[r][c] = value }
            } else if table.header.indices.contains(c) {
                table.header[c] = value
            }
        })
    }

    func cell(_ text: Binding<String>, column: Int, prompt: String) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(textAlignment(table.alignments.indices.contains(column) ? table.alignments[column] : .none))
            .frame(minWidth: 120)
    }

    func textAlignment(_ alignment: MarkdownTable.Alignment) -> TextAlignment {
        switch alignment {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }

    func columnMenu(_ c: Int) -> some View {
        Menu {
            Picker("Alignment", selection: Binding(get: { table.alignments.indices.contains(c) ? table.alignments[c] : .none },
                                                   set: { if table.alignments.indices.contains(c) { table.alignments[c] = $0 } })) {
                Text("Default").tag(MarkdownTable.Alignment.none)
                Text("Left").tag(MarkdownTable.Alignment.left)
                Text("Centre").tag(MarkdownTable.Alignment.center)
                Text("Right").tag(MarkdownTable.Alignment.right)
            }
            .pickerStyle(.inline)
            Divider()
            Button("Insert Column Left") { table.insertColumn(at: c) }
            Button("Insert Column Right") { table.insertColumn(at: c + 1) }
            Button("Move Left") { table.moveColumn(from: c, by: -1) }.disabled(c == 0)
            Button("Move Right") { table.moveColumn(from: c, by: 1) }.disabled(c == table.columnCount - 1)
            Divider()
            Button("Delete Column", role: .destructive) { table.removeColumn(at: c) }.disabled(table.columnCount == 1)
        } label: {
            Label(alignmentName(table.alignments[c]), systemImage: alignmentSymbol(table.alignments[c]))
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Alignment, and adding, moving or deleting this column")
    }

    func rowMenu(_ r: Int) -> some View {
        Menu {
            Button("Insert Row Above") { table.insertRow(at: r) }
            Button("Insert Row Below") { table.insertRow(at: r + 1) }
            Button("Move Up") { table.moveRow(from: r, by: -1) }.disabled(r == 0)
            Button("Move Down") { table.moveRow(from: r, by: 1) }.disabled(r == table.rows.count - 1)
            Divider()
            Button("Delete Row", role: .destructive) { table.removeRow(at: r) }
        } label: {
            Image(systemName: "ellipsis").accessibilityLabel("Row \(String(r + 1))")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .help("Add, move or delete this row")
    }

    func alignmentName(_ alignment: MarkdownTable.Alignment) -> String {
        switch alignment {
        case .none: String(localized: "Column")
        case .left: String(localized: "Left")
        case .center: String(localized: "Centre")
        case .right: String(localized: "Right")
        }
    }

    func alignmentSymbol(_ alignment: MarkdownTable.Alignment) -> String {
        switch alignment {
        case .none, .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        }
    }
}
