import SwiftUI
struct AdaptiveRootView:View {
 @EnvironmentObject var store:BudgetStore; @EnvironmentObject var subscriptions:SubscriptionStore
 var body:some View {
  #if os(iOS)
  iPhoneRootView()
  #else
  MacRootView()
  #endif
 }
}
#if os(iOS)
struct iPhoneRootView:View {
 @State private var tab=0
 var body:some View{TabView(selection:$tab){NavigationStack{MobileOverviewView()}.tabItem{Label("Overview",systemImage:"chart.pie.fill")}.tag(0);NavigationStack{MobileTransactionsView()}.tabItem{Label("Transactions",systemImage:"list.bullet.rectangle")}.tag(1);NavigationStack{MobileBudgetsView()}.tabItem{Label("Budgets",systemImage:"gauge.with.dots.needle.67percent")}.tag(2);NavigationStack{MobileRecurringView()}.tabItem{Label("Recurring",systemImage:"repeat.circle")}.tag(3);NavigationStack{MobileReviewView()}.tabItem{Label("Review",systemImage:"checklist")}.badge(0).tag(4)}}
}
#endif
#if os(macOS)
struct MacRootView:View {
 @State private var selection="Overview"
 var body:some View{NavigationSplitView{List(["Overview","Transactions","Budgets","Recurring","Review"],id:\.self,selection:$selection){Label($0,systemImage:icon($0))}.navigationTitle("BudgetMac Personal")}detail:{switch selection{case "Transactions":MobileTransactionsView();case "Budgets":MobileBudgetsView();case "Recurring":MobileRecurringView();case "Review":MobileReviewView();default:MobileOverviewView()}}}
 func icon(_ s:String)->String{["Overview":"chart.pie.fill","Transactions":"list.bullet.rectangle","Budgets":"gauge.with.dots.needle.67percent","Recurring":"repeat.circle","Review":"checklist"][s] ?? "circle"}
}
#endif
