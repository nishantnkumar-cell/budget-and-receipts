import SwiftUI
#if os(iOS)
import PhotosUI
import UIKit
struct MobileReceiptView:View {
 @EnvironmentObject var store:BudgetStore;let transaction:Transaction
 @State private var item:PhotosPickerItem?;@State private var image:UIImage?;@State private var editor=ReceiptDraftEditor();@State private var reviewed=false;@State private var message="Choose or photograph a receipt, then review every item.";private let vision=ReceiptVisionService()
 var body:some View{Form{if let image{Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:240)};PhotosPicker(selection:$item,matching:.images){Label("Choose receipt photo",systemImage:"photo")}.onChange(of:item){_,new in load(new)};NavigationLink{CameraCaptureView(image:$image,onSaved:scanImage)}label:{Label("Use camera",systemImage:"camera")};Section("Receipt"){TextField("Merchant",text:$editor.merchant);TextField("Total",value:$editor.receiptTotal,format:.number)};Section("Items"){ForEach($editor.items){$line in VStack{TextField("Description",text:$line.description);HStack{TextField("Amount",value:$line.total,format:.number).keyboardType(.decimalPad);Picker("Category",selection:$line.category){ForEach(FinanceCategories.all,id:\.self){Text($0).tag($0)}}}};Button("Add item"){editor.addItem()}};Section{LabeledContent("Bank",value:abs(transaction.amount) as NSDecimalNumber,format:.currency(code:"GBP"));LabeledContent("Split",value:editor.splitTotal as NSDecimalNumber,format:.currency(code:"GBP"));Toggle("I checked every item",isOn:$reviewed);Text(message).font(.caption);Button("Save draft"){store.saveDraft(editor.makeDraft(reviewed:false),for:transaction)};Button("Approve split"){var d=editor.makeDraft(reviewed:reviewed);d.receipt.reviewed=reviewed;store.approve(d,for:transaction)}.disabled(!reviewed)}}.navigationTitle("Receipt")}
 func load(_ value:PhotosPickerItem?){Task{guard let data=try? await value?.loadTransferable(type:Data.self),let ui=UIImage(data:data)else{return};await MainActor.run{image=ui};scanImage(ui)}}
 func scanImage(_ ui:UIImage){Task{do{let result=try await vision.recognise(image:ui);await MainActor.run{editor=result;message="OCR complete. Correct the draft before approval."}}catch{await MainActor.run{message=error.localizedDescription}}}}
}
}
struct CameraCaptureView:UIViewControllerRepresentable{@Environment(\.dismiss)var dismiss;@Binding var image:UIImage?;let onSaved:(UIImage)->Void;func makeUIViewController(context:Context)->UIImagePickerController{let c=UIImagePickerController();c.sourceType=.camera;c.delegate=context.coordinator;return c}func updateUIViewController(_ uiViewController:UIImagePickerController,context:Context){}func makeCoordinator()->Coordinator{Coordinator(self)}final class Coordinator:NSObject,UINavigationControllerDelegate,UIImagePickerControllerDelegate{let parent:CameraCaptureView;init(_ parent:CameraCaptureView){self.parent=parent}func imagePickerController(_ picker:UIImagePickerController,didFinishPickingMediaWithInfo info:[UIImagePickerController.InfoKey:Any]){if let image=info[.originalImage] as? UIImage{parent.image=image;parent.onSaved(image)};parent.dismiss()}}}
#endif
#if os(macOS)
struct MobileReceiptView:View{let transaction:Transaction;var body:some View{ApprovalView(transaction:transaction)}}
#endif
