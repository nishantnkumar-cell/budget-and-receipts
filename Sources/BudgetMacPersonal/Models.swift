import Foundation
struct Transaction:Identifiable,Codable,Hashable{var id:String{fingerprint};var date:Date;var merchant:String;var description:String = "";var amount:Decimal;var category:String = "Uncategorised";var fingerprint:String;var splits:[TransactionSplit]=[];var pendingSplitDraft:SplitDraft?=nil}
struct TransactionSplit:Identifiable,Codable,Hashable{var id=UUID();var label:String;var category:String;var amount:Decimal}
struct ReceiptLineItem:Identifiable,Codable,Hashable{var id=UUID();var description:String;var total:Decimal;var category="Uncategorised";var confidence:Double}
struct ReceiptRecord:Identifiable,Codable,Hashable{var id=UUID();var imagePath:String;var merchant:String;var purchaseDate:Date?;var subtotal:Decimal?;var tax:Decimal?;var total:Decimal?;var rawText:String;var items:[ReceiptLineItem];var confidence:Double;var reviewed=false}
struct SplitDraft:Identifiable,Codable,Hashable{var id=UUID();var receipt:ReceiptRecord;var proposedSplits:[TransactionSplit];var createdAt=Date();var approvedAt:Date?=nil;var splitTotal:Decimal{proposedSplits.reduce(0){$0+$1.amount}}}
struct ChangeRecord:Identifiable,Codable,Hashable{var id=UUID();let date:Date;let transactionID:String;let reason:String}
