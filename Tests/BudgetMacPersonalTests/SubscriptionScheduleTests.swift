import XCTest
@testable import BudgetMacPersonal
final class SubscriptionScheduleTests: XCTestCase {
    let calendar = Calendar(identifier: .gregorian)
    func date(_ y:Int,_ m:Int,_ d:Int)->Date { calendar.date(from:DateComponents(year:y,month:m,day:d))! }
    func testMonthlyRenewalFromEndOfMonthUsesCalendarRules(){let next=SubscriptionSchedule(calendar:calendar).nextDate(after:date(2026,1,31),period:.monthly);XCTAssertEqual(calendar.component(.month,from:next!),2)}
    func testQuarterlyAndYearlyDates(){let s=SubscriptionSchedule(calendar:calendar);XCTAssertEqual(s.nextDate(after:date(2026,1,15),period:.quarterly),date(2026,4,15));XCTAssertEqual(s.nextDate(after:date(2026,1,15),period:.yearly),date(2027,1,15))}
    func testAnnualisedMonthlyCost(){let c=SubscriptionContract(vendor:"Mobile",category:.mobile,startDate:Date(),billingPeriod:.monthly,nextPaymentDueDate:Date(),expectedAmount:31.49);XCTAssertEqual(SubscriptionSchedule().annualisedCost(c),Decimal(string:"377.88"))}
}
