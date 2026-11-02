import BudgetCore
import Foundation
import MapKit
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Finds categories for merchants the app doesn't know: first Apple Intelligence on the
/// device (nothing leaves it), then, only if switched on, an Apple Maps search that sends
/// just the merchant's name and town.
enum MerchantCategoryService {
    private static let log = Logger(subsystem: "com.nishantkumar.budgetreceipts", category: "categories")

    static func category(for merchant: String, useAI: Bool, useMaps: Bool) async -> MerchantCategory? {
        // Tests never reach Apple Intelligence or Apple Maps: the answers would vary.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        // Maps knows what kind of business a place is, so it goes first when allowed.
        if useMaps, let category = await mapsCategory(for: merchant) {
            return MerchantCategory(category: category, source: .maps)
        }
        if useAI, let category = await aiCategory(for: merchant) {
            return MerchantCategory(category: category, source: .ai)
        }
        return nil
    }

    /// Apple Intelligence's best guess, or nil when it isn't sure or isn't available.
    static func aiCategory(for merchant: String) async -> String? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: """
            You categorise UK card payments by the business that was paid. Reply with one category:
            Eating out: restaurants, takeaways, cafés, bakeries, sweet shops, fast food.
            Groceries: supermarkets, grocers, convenience stores, butchers.
            Shopping: clothes, shoes, electronics, homeware, online marketplaces, gifts.
            Health: pharmacies, doctors, dentists, opticians, gyms, hair and beauty.
            Transport: fuel, parking, trains, buses, taxis, car costs.
            Travel: flights, hotels, holidays.
            Subscriptions: streaming, apps, memberships.
            Bills & utilities: energy, water, phone, broadband, council tax, insurance.
            Housing: rent, mortgage, letting agents.
            Family: children, schools, nurseries, toys, days out.
            Savings & investments: savings and investment accounts.
            Uncategorised: when you don't recognise the business or its kind.
            Words like LTD, the town name and card codes are not clues.
            """)
        do {
            let answer = try await session.respond(to: "Statement line: \(merchant)", generating: CategoryGuess.self)
            return MerchantCategories.validated(answer.content.category)
        } catch {
            log.error("Apple Intelligence couldn't categorise a payment: \(String(describing: error), privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The kind of business Apple Maps finds for the merchant's name, as a category.
    static func mapsCategory(for merchant: String) async -> String? {
        let query = MerchantCategories.searchText(merchant)
        guard query.count >= 3 else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        // Around the UK, where the statements come from.
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 54.0, longitude: -2.5), span: MKCoordinateSpan(latitudeDelta: 12, longitudeDelta: 12))
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        for item in response.mapItems.prefix(3) {
            if let kind = item.pointOfInterestCategory?.rawValue, let category = MerchantCategories.mapsCategories[kind] {
                return category
            }
        }
        return nil
    }
}

#if canImport(FoundationModels)
@Generable
struct CategoryGuess {
    @Guide(description: "One category from the list in the instructions", .anyOf(FinanceCategories.all))
    var category: String
}
#endif
