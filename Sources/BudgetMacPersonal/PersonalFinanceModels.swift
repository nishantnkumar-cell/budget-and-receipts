import Foundation
struct MonthlyBudget: Identifiable, Codable, Hashable { var id=UUID(); var category:String; var limit:Decimal; var month:Date }
struct ImportRecord: Identifiable, Codable, Hashable { var id=UUID(); var fileName:String; var importedAt=Date(); var transactionCount:Int; var status:String }
enum FinanceCategories { static let all=["Housing","Bills & utilities","Groceries","Eating out","Transport","Shopping","Health","Family","Subscriptions","Travel","Savings & investments","Income","Card payment","Internal transfer","Uncategorised"] }
