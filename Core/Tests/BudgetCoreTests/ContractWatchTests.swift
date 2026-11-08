import XCTest
@testable import BudgetCore

final class ContractWatchTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ month: Int, _ day: Int, year: Int = 2026, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func contract(_ configure: (inout SubscriptionContract) -> Void = { _ in }) -> SubscriptionContract {
        var contract = SubscriptionContract(vendor: "Vodafone", category: .mobile, startDate: day(1, 1, year: 2025), minimumTermEndDate: day(12, 31),
                                            billingPeriod: .monthly, nextPaymentDueDate: day(11, 20), expectedAmount: money("30.00"), kind: .contract)
        configure(&contract)
        return contract
    }

    private var watch: ContractWatch { ContractWatch(calendar: calendar) }

    func testFarOffContractIsQuiet() {
        XCTAssertNil(watch.urgency(contract(), now: day(6, 1)))
    }

    func testEndingSoonWithinSixtyDays() {
        XCTAssertEqual(watch.urgency(contract(), now: day(11, 8)), .endingSoon(day(12, 31), days: 53))
    }

    func testNoticeDeadlineComesFirst() {
        let item = contract { $0.cancellationNoticeDays = 30 }
        XCTAssertEqual(watch.urgency(item, now: day(11, 8)), .giveNoticeBy(day(12, 1), days: 23))
        XCTAssertTrue(watch.urgency(item, now: day(11, 8))!.isUrgent)
    }

    func testNoticeMissedOnceDeadlinePasses() {
        let item = contract { $0.cancellationNoticeDays = 30 }
        XCTAssertEqual(watch.urgency(item, now: day(12, 10)), .noticeMissed(ends: day(12, 31), days: 21))
    }

    func testRenewalDateWinsOverTermEnd() {
        let item = contract { $0.renewalDate = day(11, 30) }
        XCTAssertEqual(watch.urgency(item, now: day(11, 8))?.date, day(11, 30))
    }

    func testEndedThenGoesQuiet() {
        XCTAssertEqual(watch.urgency(contract(), now: day(1, 10, year: 2027)), .ended(day(12, 31)))
        XCTAssertNil(watch.urgency(contract(), now: day(6, 1, year: 2027)))
    }

    func testSubscriptionsAndInactiveAreIgnored() {
        XCTAssertNil(watch.urgency(contract { $0.kind = .subscription }, now: day(12, 20)))
        XCTAssertNil(watch.urgency(contract { $0.status = .cancelled }, now: day(12, 20)))
    }

    func testMostPressingFirst() {
        let ending = contract { $0.vendor = "EE" }
        let notice = contract { $0.vendor = "Octopus"; $0.cancellationNoticeDays = 30 }
        XCTAssertEqual(watch.needingAttention([ending, notice], now: day(11, 8)).map(\.contract.vendor), ["Octopus", "EE"])
    }

    func testDocumentsRoundTripAndOldItemsDecode() throws {
        var item = contract()
        item.documents = [ContractDocument(fileName: "\(UUID().uuidString).pdf", title: "Signed contract", added: day(1, 1))]
        let data = try SyncRecord.encoder().encode(item)
        XCTAssertEqual(try SyncRecord.decoder().decode(SubscriptionContract.self, from: data).documents, item.documents)
        XCTAssertTrue(item.documents![0].isPDF)
        var old = contract()
        old.documents = nil
        let decoded = try SyncRecord.decoder().decode(SubscriptionContract.self, from: SyncRecord.encoder().encode(old))
        XCTAssertNil(decoded.documents)
    }

    func testTermEndRemindersWithoutRenewal() {
        let reminders = ReminderPlanner(calendar: calendar).reminders(for: contract { $0.cancellationNoticeDays = 30 }, now: day(11, 1))
        XCTAssertEqual(reminders.first { $0.kind == .cancellationDeadline }?.eventDate, day(12, 1))
        XCTAssertEqual(reminders.first { $0.kind == .contractEnds }?.fireDate, day(12, 1, hour: 9))
        XCTAssertNil(reminders.first { $0.kind == .renewal })
    }
}
