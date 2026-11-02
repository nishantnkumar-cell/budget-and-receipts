import SwiftUI
@MainActor final class BudgetStore: ObservableObject {
    @Published var transactions:[Transaction]=[]
    @Published var changes:[ChangeRecord]=[]
    @Published var budgets:[MonthlyBudget]=[]
    @Published var imports:[ImportRecord]=[]
    @Published var status="Import statements or add a transaction."
    private let folder:URL
    init(){
        folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("BudgetMacPersonal",isDirectory:true)
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        transactions=load("transactions.json") ?? []; budgets=load("budgets.json") ?? []; imports=load("imports.json") ?? []
    }
    func saveDraft(_ draft:SplitDraft,for transaction:Transaction){guard let i=transactions.firstIndex(where:{$0.id==transaction.id})else{return};transactions[i].pendingSplitDraft=draft;persist();status="Draft saved. No splits were created."}
    func approve(_ draft:SplitDraft,for transaction:Transaction){guard let i=transactions.firstIndex(where:{$0.id==transaction.id})else{return};guard case .success = SplitApprovalPolicy().validate(draft,bankAmount:transactions[i].amount,reviewed:draft.receipt.reviewed) else{status="Approval blocked by validation.";return};transactions[i].splits=draft.proposedSplits;transactions[i].pendingSplitDraft=nil;changes.append(ChangeRecord(date:Date(),transactionID:transaction.id,reason:"Approved receipt split after manual review"));persist();status="Approved and created \(draft.proposedSplits.count) splits."}
    func addTransaction(){let tx=Transaction(date:Date(),merchant:"New transaction",description:"Manual entry",amount:0,category:"Uncategorised",fingerprint:UUID().uuidString);transactions.insert(tx,at:0);persist()}
    func update(_ tx:Transaction){guard let i=transactions.firstIndex(where:{$0.id==tx.id})else{return};transactions[i]=tx;persist()}
    func delete(_ tx:Transaction){transactions.removeAll{$0.id==tx.id};persist()}
    func setBudget(category:String,limit:Decimal,month:Date=Date()){let cal=Calendar.current;if let i=budgets.firstIndex(where:{$0.category==category && cal.isDate($0.month,equalTo:month,toGranularity:.month)}){budgets[i].limit=limit}else{budgets.append(MonthlyBudget(category:category,limit:limit,month:month))};persist()}
    var spending:Decimal{transactions.filter{$0.amount<0 && $0.category != "Card payment" && $0.category != "Internal transfer"}.reduce(0){$0-$1.amount}}
    var income:Decimal{transactions.filter{$0.amount>0 && $0.category != "Internal transfer"}.reduce(0){$0+$1.amount}}
    var needsReview:[Transaction]{transactions.filter{$0.category=="Uncategorised" || $0.pendingSplitDraft != nil}}
    func recordImport(fileName:String,count:Int,status:String){imports.insert(ImportRecord(fileName:fileName,transactionCount:count,status:status),at:0);persist()}
    private func persist(){save(transactions,"transactions.json");save(budgets,"budgets.json");save(imports,"imports.json")}
    private func save<T:Encodable>(_ value:T,_ name:String){let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];if let d=try? e.encode(value){try? d.write(to:folder.appendingPathComponent(name),options:.atomic)}}
    private func load<T:Decodable>(_ name:String)->T?{guard let d=try? Data(contentsOf:folder.appendingPathComponent(name))else{return nil};return try? JSONDecoder().decode(T.self,from:d)}
}
