import XCTest
@testable import BudgetMacPersonal
final class SubscriptionReminderTests:XCTestCase{
 let cal=Calendar(identifier:.gregorian);func d(_ y:Int,_ m:Int,_ day:Int)->Date{cal.date(from:DateComponents(year:y,month:m,day:day))!}
 func testDueSoonWindow(){let now=d(2026,11,1);let a=SubscriptionContract(vendor:"A",category:.insurance,startDate:now,billingPeriod:.yearly,nextPaymentDueDate:d(2026,11,20),expectedAmount:100);let b=SubscriptionContract(vendor:"B",category:.energy,startDate:now,billingPeriod:.monthly,nextPaymentDueDate:d(2026,12,15),expectedAmount:50);XCTAssertEqual(SubscriptionTracker().dueSoon([a,b],from:now,days:30).map(\.vendor),["A"])}
 func testRenewalSoonIgnoresCancelled(){let now=d(2026,11,1);var c=SubscriptionContract(vendor:"Insurance",category:.insurance,startDate:now,renewalDate:d(2026,11,20),billingPeriod:.yearly,nextPaymentDueDate:d(2026,11,20),expectedAmount:200);c.status = .cancelled;XCTAssertTrue(SubscriptionTracker().renewalSoon([c],from:now).isEmpty)}
}
