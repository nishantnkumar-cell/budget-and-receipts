import SwiftUI
import TaxCore

struct TaxPropertiesView: View {
    @EnvironmentObject var tax: TaxStore
    @State private var editing: RentalProperty?

    var body: some View {
        Form {
            Section {
                ForEach(tax.book.properties) { property in
                    Button { editing = property } label: {
                        LabeledContent(property.name, value: "You \(property.myShare * 100)%").contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("Add Property", systemImage: "plus") { editing = RentalProperty(name: "") }
            } footer: {
                Text("You can also tag a payment “Property: ” followed by the property's name.")
            }
            if !tax.book.rules.isEmpty {
                Section("Rules (the first that matches wins)") {
                    ForEach(tax.book.rules) { rule in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Contains “\(rule.merchantContains)”")
                                Text("\(tax.book.properties.first { $0.id == rule.propertyID }?.name ?? "Unknown") · \(rule.category.title)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                tax.change { book in book.rules.removeAll { $0.id == rule.id } }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Properties and Rules")
        .sheet(item: $editing) { TaxPropertyEditor(property: $0) }
    }
}

private struct TaxPropertyEditor: View {
    @EnvironmentObject var tax: TaxStore
    let property: RentalProperty
    @State private var name = ""
    @State private var share = "50"
    @State private var form17 = false
    @State private var declared = Date()

    private var percent: Decimal? {
        guard let value = TaxMoney.parse(share), value <= 100 else { return nil }
        return value
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameTaken: Bool {
        tax.book.properties.contains { $0.id != property.id && $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }
    }

    var body: some View {
        let exists = tax.book.properties.contains { $0.id == property.id }
        TaxSheet(title: exists ? "Property" : "New property", canSave: !trimmed.isEmpty && !nameTaken && percent != nil) {
            guard let percent else { return }
            // Noon in London, so the date is the same day everywhere.
            let day = TaxYear.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: declared) ?? declared
            var saved = RentalProperty(id: property.id, name: trimmed, myShare: percent / 100)
            if form17 && saved.isUnequalJoint { saved.form17From = TaxYear.calendar.startOfDay(for: day) }
            tax.change { book in
                if let index = book.properties.firstIndex(where: { $0.id == saved.id }) {
                    book.properties[index] = saved
                } else {
                    book.properties.append(saved)
                }
            }
        } content: {
            Section {
                TextField("Name", text: $name, prompt: Text("e.g. 12 Sample Street"))
                    .accessibilityIdentifier("Property name")
                if nameTaken { Text("Another property has this name.").foregroundStyle(.red) }
            }
            Section {
                LabeledContent("Your share (%)") {
                    TextField("Your share", text: $share).labelsHidden().multilineTextAlignment(.trailing)
                }
                if let percent { LabeledContent("Spouse's share", value: "\(100 - percent)%") }
                if let percent, percent > 0, percent < 100, percent != 50 {
                    Toggle("Form 17 sent to HMRC", isOn: $form17)
                    if form17 { DatePicker("Date signed", selection: $declared, displayedComponents: .date) }
                }
            } footer: {
                Text("A married couple's joint property is taxed half each unless HMRC has a Form 17 showing the real unequal shares. It must reach HMRC within 60 days of signing, and applies from the signing date. Enter 100 or 0 only if the property is in one name.")
            }
            if exists {
                TaxRemoveButton(title: "Remove Property",
                                warning: "Its rules, chosen payments, agent statements and interest figures are removed too, on all your devices. Payments stay.") {
                    tax.change { $0.removeProperty(property.id) }
                }
            }
        }
        .onAppear {
            name = property.name
            share = "\(property.myShare * 100)"
            form17 = property.form17From != nil
            declared = property.form17From ?? Date()
        }
    }
}
