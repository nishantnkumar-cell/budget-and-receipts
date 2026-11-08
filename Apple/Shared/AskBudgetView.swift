import BudgetCore
import SwiftUI

/// Ask your budget a question in your own words. Answered on this device.
struct AskBudgetView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var exchanges: [(id: UUID, question: String, answer: String?)] = []
    @FocusState private var focused: Bool

    private let suggestions = ["How much is left this month?", "What did I spend on eating out?", "When's my next bill?", "Where do I spend the most?"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if exchanges.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Ask your budget", systemImage: "sparkles").font(.headline).foregroundStyle(Color.brandPink)
                            Text("Questions are answered on this device from your own figures. Nothing is sent anywhere.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let limitation = BudgetAssistant.limitation {
                                Text(limitation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button { ask(suggestion) } label: {
                                Text(suggestion).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    ForEach(exchanges, id: \.id) { exchange in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(exchange.question)
                                .padding(10)
                                .background(Color.brandPink.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            if let answer = exchange.answer {
                                Text(answer)
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else {
                                ProgressView().padding(10)
                            }
                        }
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                TextField("Ask about spending, budgets or bills", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { ask(question) }
                Button { ask(question) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Ask")
            }
            .padding()
        }
        .navigationTitle("Ask")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear { focused = true }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private func ask(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = UUID()
        exchanges.append((id, text, nil))
        question = ""
        Task {
            let answer = await BudgetAssistant.answer(text, store: store, subscriptions: subscriptions)
            if let index = exchanges.firstIndex(where: { $0.id == id }) { exchanges[index].answer = answer }
        }
    }
}

/// The toolbar button that opens Ask.
struct AskBudgetButton: View {
    @State private var asking = false

    var body: some View {
        Button { asking = true } label: { Image(systemName: "sparkles") }
            .accessibilityLabel("Ask your budget")
            .help("Ask your budget")
            .sheet(isPresented: $asking) { NavigationStack { AskBudgetView() } }
    }
}
