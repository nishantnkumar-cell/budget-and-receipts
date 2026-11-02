import Foundation
import Vision
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
struct ReceiptDraftEditor:Hashable{var merchant="";var purchaseDate:Date?;var subtotal:Decimal?;var tax:Decimal?;var receiptTotal:Decimal?;var items:[ReceiptLineItem]=[];var splitTotal:Decimal{items.reduce(0){$0+$1.total}};mutating func addItem(){items.append(ReceiptLineItem(description:"New item",total:0,confidence:1))};func makeDraft(reviewed:Bool)->SplitDraft{let r=ReceiptRecord(imagePath:"",merchant:merchant,purchaseDate:purchaseDate,subtotal:subtotal,tax:tax,total:receiptTotal,rawText:"",items:items,confidence:1,reviewed:reviewed);return SplitDraft(receipt:r,proposedSplits:items.map{TransactionSplit(label:$0.description,category:$0.category,amount:$0.total)})}}
actor ReceiptVisionService {
 #if os(iOS)
 func recognise(image:UIImage)throws->ReceiptDraftEditor{guard let cg=image.cgImage else{throw CocoaError(.fileReadCorruptFile)};return try recognise(cg:cg)}
 #endif
 #if os(macOS)
 func recognise(url:URL)throws->ReceiptDraftEditor{guard let image=NSImage(contentsOf:url),let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil)else{throw CocoaError(.fileReadCorruptFile)};return try recognise(cg:cg)}
 #endif
 private func recognise(cg:CGImage)throws->ReceiptDraftEditor{let r=VNRecognizeTextRequest();r.recognitionLevel = .accurate;r.usesLanguageCorrection=true;r.recognitionLanguages=["en-GB","en-US"];try VNImageRequestHandler(cgImage:cg).perform([r]);let lines=(r.results ?? []).compactMap{$0.topCandidates(1).first?.string};guard !lines.isEmpty else{throw CocoaError(.fileReadUnknown)};return ReceiptParser.parse(lines)}
}
enum ReceiptParser{static func parse(_ lines:[String])->ReceiptDraftEditor{let money=lines.compactMap{line->(String,Decimal)? in guard let a=amountAtEnd(line)else{return nil};return(line,a)};let total=money.last(where:{$0.0.range(of:"(?i)(grand total|amount due|total)",options:.regularExpression) != nil})?.1 ?? money.last?.1;let items=money.compactMap{line,a->ReceiptLineItem? in guard line.range(of:"(?i)(total|subtotal|vat|tax|cash|change|card)",options:.regularExpression)==nil else{return nil};let name=line.replacingOccurrences(of:"[£$€]?\\s*-?\\d+[.,]\\d{2}\\s*$",with:"",options:.regularExpression).trimmingCharacters(in:.whitespaces);return name.isEmpty ? nil:ReceiptLineItem(description:name,total:a,confidence:1)};return ReceiptDraftEditor(merchant:lines.first ?? "",receiptTotal:total,items:items)};static func amountAtEnd(_ line:String)->Decimal?{guard let range=line.range(of:"[£$€]?\\s*-?\\d+(?:,\\d{3})*[.,]\\d{2}\\s*$",options:.regularExpression)else{return nil};let v=String(line[range]).replacingOccurrences(of:"£",with:"").replacingOccurrences(of:"$",with:"").replacingOccurrences(of:"€",with:"").replacingOccurrences(of:",",with:"").trimmingCharacters(in:.whitespaces);return Decimal(string:v)}}
