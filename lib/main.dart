import 'dart:convert';
import 'dart:ui' show instantiateImageCodec;
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'dart:math';
import 'package:mobile_scanner/mobile_scanner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await openDatabase(p.join(await getDatabasesPath(), 'mr_vision.db'), version: 11, onUpgrade: (d,old,v) async {if(old<8){await d.execute("ALTER TABLE products ADD COLUMN image_data TEXT DEFAULT ''");}if(old<7){await d.execute("ALTER TABLE lines ADD COLUMN serials TEXT DEFAULT ''");await d.execute("ALTER TABLE lines ADD COLUMN warranty_snapshot TEXT DEFAULT ''");}if(old<6){for(final col in ["hsn TEXT DEFAULT ''","unit TEXT DEFAULT 'PCS'","brand TEXT DEFAULT ''","warranty TEXT DEFAULT ''","min_stock INTEGER DEFAULT 5"]){await d.execute("ALTER TABLE products ADD COLUMN $col");}}if(old<5){await d.execute('ALTER TABLE lines ADD COLUMN product_id INTEGER');}if(old<2){await d.execute('ALTER TABLE products ADD COLUMN cost REAL');await d.execute('ALTER TABLE products ADD COLUMN category TEXT DEFAULT \'General\'');await d.execute('ALTER TABLE products ADD COLUMN barcode TEXT');await d.execute('ALTER TABLE lines ADD COLUMN cost REAL');}if(old<3){await d.execute('ALTER TABLE sales ADD COLUMN paid REAL');await d.execute('ALTER TABLE sales ADD COLUMN payment_mode TEXT');}}, onCreate: (d,v) async {
    await d.execute('CREATE TABLE products(id INTEGER PRIMARY KEY, code TEXT UNIQUE, name TEXT, price REAL, qty INTEGER, gst REAL, cost REAL, category TEXT, barcode TEXT, hsn TEXT, unit TEXT, brand TEXT, warranty TEXT, min_stock INTEGER DEFAULT 5, image_data TEXT DEFAULT NULL)');
    await d.execute('CREATE TABLE clients(id INTEGER PRIMARY KEY, name TEXT, phone TEXT, address TEXT)');
    await d.execute('CREATE TABLE sales(id INTEGER PRIMARY KEY, number TEXT UNIQUE, date TEXT, customer TEXT, total REAL, paid REAL, payment_mode TEXT)');
    await d.execute("CREATE TABLE lines(id INTEGER PRIMARY KEY, sale INTEGER, name TEXT, qty INTEGER, price REAL, gst REAL, cost REAL, product_id INTEGER, serials TEXT DEFAULT '', warranty_snapshot TEXT DEFAULT '')");
  });
  await db.execute('CREATE TABLE IF NOT EXISTS collections(id INTEGER PRIMARY KEY, sale INTEGER NOT NULL, date TEXT NOT NULL, amount REAL NOT NULL, mode TEXT NOT NULL)');
  await db.execute('CREATE TABLE IF NOT EXISTS invoice_edits(id INTEGER PRIMARY KEY, sale INTEGER NOT NULL, date TEXT NOT NULL, snapshot TEXT NOT NULL)');
  await db.execute('CREATE TABLE IF NOT EXISTS preferences(k TEXT PRIMARY KEY, v TEXT)');
  await db.transaction((tx) async {
    await tx.execute("CREATE TABLE IF NOT EXISTS stock_movements(id INTEGER PRIMARY KEY, product_id INTEGER NOT NULL, code TEXT NOT NULL, name TEXT NOT NULL, date TEXT NOT NULL, before_qty INTEGER NOT NULL, after_qty INTEGER NOT NULL, reason TEXT NOT NULL)");
    await tx.execute("INSERT INTO stock_movements(product_id,code,name,date,before_qty,after_qty,reason) SELECT p.id,p.code,p.name,strftime('%Y-%m-%dT%H:%M:%fZ','now'),0,p.qty,'Opening balance' FROM products p WHERE NOT EXISTS(SELECT 1 FROM stock_movements m WHERE m.product_id=p.id)");
    await tx.execute("CREATE TRIGGER IF NOT EXISTS stock_insert AFTER INSERT ON products BEGIN INSERT INTO stock_movements(product_id,code,name,date,before_qty,after_qty,reason) VALUES(NEW.id,NEW.code,NEW.name,strftime('%Y-%m-%dT%H:%M:%fZ','now'),0,NEW.qty,'Opening balance'); END");
    await tx.execute("CREATE TRIGGER IF NOT EXISTS stock_update AFTER UPDATE OF qty ON products WHEN OLD.qty != NEW.qty BEGIN INSERT INTO stock_movements(product_id,code,name,date,before_qty,after_qty,reason) VALUES(NEW.id,NEW.code,NEW.name,strftime('%Y-%m-%dT%H:%M:%fZ','now'),OLD.qty,NEW.qty,'Stock change'); END");
  });

  await db.transaction((tx) async {
    await tx.execute("CREATE TABLE IF NOT EXISTS suppliers(id INTEGER PRIMARY KEY, name TEXT NOT NULL, phone TEXT NOT NULL, address TEXT NOT NULL)");
    await tx.execute("CREATE TABLE IF NOT EXISTS purchases(id INTEGER PRIMARY KEY, supplier_id INTEGER NOT NULL, number TEXT NOT NULL, date TEXT NOT NULL, total REAL NOT NULL, paid REAL NOT NULL, UNIQUE(supplier_id,number))");
    await tx.execute("CREATE TABLE IF NOT EXISTS purchase_lines(id INTEGER PRIMARY KEY, purchase_id INTEGER NOT NULL, product_id INTEGER NOT NULL, name TEXT NOT NULL, qty INTEGER NOT NULL, cost REAL NOT NULL)");
  });
  await db.execute("CREATE TABLE IF NOT EXISTS supplier_events(id INTEGER PRIMARY KEY, purchase_id INTEGER NOT NULL, date TEXT NOT NULL, amount REAL NOT NULL, mode TEXT NOT NULL, snapshot TEXT NOT NULL)");
  final settings={for(final r in await db.query('preferences')) r['k'] as String:r['v'] as String};
  runApp(ERP(db:db,settings:settings));
}
String money(num n) => NumberFormat.currency(locale:'en_IN',symbol:'₹').format(n);
class ERP extends StatefulWidget {
  final Database db; final Map<String,String> settings; const ERP({super.key,required this.db,required this.settings});
  @override State<ERP> createState()=>_ERPState();
}
class _ERPState extends State<ERP> {
  static const names=['Royal Blue','Emerald Green','Midnight Dark','Luxury Gold','Ocean Teal','Premium Purple','Crimson Red','Minimal White'];
  static const colors=[0xff1759d1,0xff059669,0xff818cf8,0xffb58b22,0xff0891b2,0xff8b5cf6,0xffe11d48,0xff475569];
  Future<void> save(String k,String v) async {await widget.db.insert('preferences',{'k':k,'v':v},conflictAlgorithm:ConflictAlgorithm.replace);if(mounted)setState(()=>widget.settings[k]=v);}
  Future<void> reloadSettings() async {final rows=await widget.db.query('preferences');if(mounted)setState((){widget.settings.clear();widget.settings.addAll({for(final r in rows) r['k'] as String:r['v'] as String});});}
  @override Widget build(BuildContext context){final i=(int.tryParse(widget.settings['theme']??'0')??0).clamp(0,7).toInt();final dark=widget.settings['dark']=='1'||i==2||i==3;final scheme=ColorScheme.fromSeed(seedColor:Color(colors[i]),brightness:dark?Brightness.dark:Brightness.light);return MaterialApp(debugShowCheckedModeBanner:false,title:'MR Vision Tech',theme:ThemeData(useMaterial3:true,colorScheme:scheme,cardTheme:CardThemeData(margin:const EdgeInsets.symmetric(vertical:5),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(20)))),home:Home(db:widget.db,dark:dark,toggle:()=>save('dark',dark?'0':'1'),settings:widget.settings,save:save,reloadSettings:reloadSettings));}

}
class Home extends StatefulWidget {
 final Database db; final bool dark; final VoidCallback toggle; final Map<String,String> settings; final Future<void> Function(String,String) save;
 final Future<void> Function() reloadSettings;
 const Home({super.key,required this.db,required this.dark,required this.toggle,required this.settings,required this.save,required this.reloadSettings});
 @override State<Home> createState()=>_HomeState();
}
class _HomeState extends State<Home> {
 bool _exitDialogOpen = false;
 Future<void> _confirmExit() async {
   if (_exitDialogOpen || !mounted) return;
   _exitDialogOpen = true;
   try {
     final exit = await showDialog<bool>(
       context: context,
       barrierDismissible: false,
       builder: (dialogContext) => AlertDialog(
         icon: const Icon(Icons.exit_to_app),
         title: const Text('Exit MR Vision Tech?'),
         content: const Text('Are you sure you want to close the app? Unsaved entries may be lost.'),
         actions: [
           TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
           FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Exit')),
         ],
       ),
     );
     if (exit == true && mounted) await SystemNavigator.pop();
   } finally {
     _exitDialogOpen = false;
   }
 }

 int tab=0; String search=''; String category='All'; String? brandFilter; bool lowOnly=false; bool busy=false; int? client;
 List<Map<String,Object?>> products=[],clients=[],sales=[],collections=[],allLines=[]; final Map<int,int> cart={};
 @override void initState(){super.initState(); refresh();}
 Future<void> refresh() async {final a=await widget.db.query('products',orderBy:'name');final b=await widget.db.query('clients',orderBy:'name');final c=await widget.db.query('sales',orderBy:'id DESC');final d=await widget.db.query('collections',orderBy:'id DESC');final e=await widget.db.query('lines');if(mounted)setState((){products=a;clients=b;sales=c;collections=d;allLines=e;});}
 final List<int> history=[];
 void go(int i){if(i==tab)return;setState((){if(i==0){history.clear();}else{history.add(tab);}tab=i;search='';});}
 void back(){if(tab==0){_confirmExit();return;}setState((){tab=history.isEmpty?0:history.removeLast();search='';});}
 void message(String s){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));}
 double total(Map<String,Object?> r,int q)=>(r['price'] as num).toDouble()*q*(1+(r['gst'] as num)/100);
 double get cartTotal=>products.fold(0.0,(s,r)=>s+total(r,cart[r['id']]??0));
 Future<void> scanProduct({required bool billing}) async {
 if(busy)return;
 final code=await Navigator.push<String>(context,MaterialPageRoute(builder:(_)=>const BarcodeScanPage()));
 if(!mounted||code==null||busy)return;
 final matches=products.where((r)=>r['barcode']?.toString().trim()==code||r['code']?.toString().trim()==code).toList();
 if(matches.isEmpty){message('No product found: $code');return;}
 if(matches.length!=1){message('Multiple products match. Resolve duplicate barcodes in Inventory.');return;}
 final r=matches.single;
 if(!billing){await edit(true,r);return;}
 final id=r['id'] as int;final q=cart[id]??0;
 if(q>=(r['qty'] as int)){message('Insufficient stock');return;}
 setState(()=>cart[id]=q+1);message('Added ${r['name']} to cart');
 }
 Future<void> barcodeLabel(Map<String,Object?> r) async {
 final stored=(r['barcode']??'').toString().trim();final code=stored.isEmpty?r['code'].toString():stored;
 try {
 final doc=pw.Document();doc.addPage(pw.Page(pageFormat:PdfPageFormat.a4,build:(_)=>pw.Align(alignment:pw.Alignment.topLeft,child:pw.Container(width:200,padding:const pw.EdgeInsets.all(10),child:pw.Column(mainAxisSize:pw.MainAxisSize.min,children:[pw.Text(r['name'].toString()),pw.SizedBox(height:8),pw.BarcodeWidget(barcode:pw.Barcode.code128(),data:code,width:180,height:60),pw.Text(code)])))));
 final bytes=await doc.save();if(!mounted)return;
 await Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Barcode label')),body:PdfPreview(build:(_) async=>bytes))));
 }catch(e){message('Cannot generate barcode: $e');}
 }
 Future<void> edit(bool product,[Map<String,Object?>? record]) async {
 final v=await Navigator.of(context).push<List<String>>(MaterialPageRoute(builder:(_)=>_RecordDialog(product:product,record:record,categories:products.map((r)=>(r['category']??'General').toString()).toSet().toList(),brands:products.map((r)=>(r['brand']??'').toString()).toSet().toList())));
 if(!mounted||v==null)return;
 try{if(product){final price=double.tryParse(v[2]);final qty=int.tryParse(v[3]);final gst=double.tryParse(v[4]);if(v[0].isEmpty||v[1].isEmpty||price==null||!price.isFinite||price<0||qty==null||qty<0||gst==null||!gst.isFinite||gst<0||gst>100)throw Exception('Enter valid product details');final cost=v[5].isEmpty?null:double.tryParse(v[5]);if(v[5].isNotEmpty&&(cost==null||!cost.isFinite||cost<0))throw Exception('Invalid purchase price');final minimum=int.tryParse(v[12]);if(minimum==null||minimum<0)throw Exception('Invalid minimum stock');if(v[7].isNotEmpty){final duplicates=await widget.db.query('products',where:'(barcode=? OR code=?) AND id != ?',whereArgs:[v[7],v[7],record?['id']??-1]);if(duplicates.isNotEmpty)throw Exception('Barcode already assigned');}final codeMatches=await widget.db.query('products',where:'barcode=? AND id != ?',whereArgs:[v[0],record?['id']??-1]);if(codeMatches.isNotEmpty)throw Exception('Item code conflicts with another barcode');final data={'code':v[0],'name':v[1],'price':price,'qty':qty,'gst':gst,'cost':cost,'category':v[6],'barcode':v[7],'hsn':v[8],'unit':v[9].isEmpty?'PCS':v[9],'brand':v[10],'warranty':v[11],'min_stock':minimum,'image_data':v[13]};if(record==null){await widget.db.insert('products',data);}else{await widget.db.update('products',data,where:'id=?',whereArgs:[record['id']]);cart.clear();}}else{if(v[0].isEmpty)throw Exception('Name is required');final data={'name':v[0],'phone':v[1],'address':v[2]};if(record==null){await widget.db.insert('clients',data);}else{await widget.db.update('clients',data,where:'id=?',whereArgs:[record['id']]);}}await refresh();message('Saved successfully');}catch(e){message('Could not save: $e');}
 }
 Future<void> checkout() async {if(busy||!cart.values.any((q)=>q>0))return;setState(()=>busy=true);try{final serialData=<int,String>{};for(final r in products){final q=cart[r['id']]??0;if(q<=0)continue;final value=await showDialog<String>(context:context,builder:(_)=>SerialEntryDialog(name:r['name'].toString(),qty:q));if(value==null||!mounted)return;serialData[r['id'] as int]=value;}final payment=await showDialog<Map<String,Object?>>(context:context,builder:(_)=>PaymentDialog(total:cartTotal));if(payment==null||!mounted)return;final number='MR-${DateFormat('ddMMyy').format(DateTime.now())}-${Random.secure().nextInt(0x10000).toRadixString(16).padLeft(4,'0').toUpperCase()}';await widget.db.transaction((tx) async {final id=await tx.insert('sales',{'number':number,'date':DateTime.now().toIso8601String(),'customer':clients.firstWhere((r)=>r['id']==client,orElse:()=>{'name':'Walk-in'})['name'],'total':cartTotal,'paid':payment['paid'],'payment_mode':payment['mode']});for(final r in products){final q=cart[r['id']]??0;if(q==0)continue;final changed=await tx.rawUpdate('UPDATE products SET qty=qty-? WHERE id=? AND qty>=?',[q,r['id'],q]);if(changed!=1)throw Exception('Insufficient stock');await tx.rawUpdate("UPDATE stock_movements SET reason=? WHERE id=(SELECT MAX(id) FROM stock_movements WHERE product_id=?)",['Sale $number',r['id']]);await tx.insert('lines',{'sale':id,'product_id':r['id'],'name':r['name'],'qty':q,'price':r['price'],'gst':r['gst'],'cost':r['cost'],'serials':serialData[r['id']]??'','warranty_snapshot':r['warranty']?.toString()??''});}await validateSerials(tx);});cart.clear();await refresh();if(mounted){go(3);message('Invoice saved');}}catch(e){message('Sale failed: $e');}finally{if(mounted)setState(()=>busy=false);}}
 double collected(Map<String,Object?> r)=>collections.where((c)=>c['sale']==r['id']).fold<double>(0,(a,c)=>a+(c['amount'] as num).toDouble());
 double? outstanding(Map<String,Object?> r)=>r['paid']==null?null:max(0.0,(r['total'] as num).toDouble()-(r['paid'] as num).toDouble()-collected(r));
 String amountWords(double value){
 final small=['Zero','One','Two','Three','Four','Five','Six','Seven','Eight','Nine','Ten','Eleven','Twelve','Thirteen','Fourteen','Fifteen','Sixteen','Seventeen','Eighteen','Nineteen'];
 final tens=['','','Twenty','Thirty','Forty','Fifty','Sixty','Seventy','Eighty','Ninety'];
 String words(int n){if(n<20)return small[n];if(n<100)return tens[n~/10]+(n%10==0?'':' ${words(n%10)}');for(final unit in [10000000,100000,1000,100]){if(n>=unit){final label={10000000:'Crore',100000:'Lakh',1000:'Thousand',100:'Hundred'}[unit];return '${words(n~/unit)} $label${n%unit==0?'':' ${words(n%unit)}'}';}}return '';}
 final cents=(value*100).round();return 'Rupees ${words(cents~/100)}${cents%100==0?'':' and ${words(cents%100)} Paise'} Only';}
 Future<void> report(String title,List<List<String>> rows,List<String> headers) async {final doc=pw.Document();doc.addPage(pw.MultiPage(pageFormat:PdfPageFormat.a4,build:(_)=>[pw.Text(widget.settings['business']??'MR Vision Tech'),pw.Text(title,style:pw.TextStyle(fontSize:18,fontWeight:pw.FontWeight.bold)),pw.SizedBox(height:12),pw.TableHelper.fromTextArray(headers:headers,data:rows,cellStyle:const pw.TextStyle(fontSize:9))]));final bytes=await doc.save();if(!mounted)return;await Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>Scaffold(appBar:AppBar(title:Text(title)),body:PdfPreview(build:(_) async=>bytes))));}
 Future<void> collect(Map<String,Object?> r) async {final due=outstanding(r);if(due==null||due<=0||busy)return;setState(()=>busy=true);try{final payment=await showDialog<Map<String,Object?>>(context:context,builder:(_)=>PaymentDialog(total:due));if(payment==null)return;final amount=(payment['paid'] as num).toDouble();if(amount<=0)return;final mode=payment['mode'].toString();final date=DateTime.now().toIso8601String();final id=await widget.db.transaction((tx) async {final old= (await tx.query('sales',where:'id=?',whereArgs:[r['id']])).single;final rows=await tx.query('collections',where:'sale=?',whereArgs:[r['id']]);final sum=rows.fold<double>(0,(a,c)=>a+(c['amount'] as num).toDouble());if(old['paid']==null||amount>((old['total'] as num)-(old['paid'] as num)-sum)+0.000001)throw Exception('Amount exceeds outstanding');return tx.insert('collections',{'sale':r['id'],'date':date,'amount':amount,'mode':mode});});await refresh();await report('Payment receipt $id',[[r['number'].toString(),r['customer'].toString(),date,mode,money(amount).replaceAll('₹','INR ')]],['Invoice','Customer','Date','Mode','Received']);}catch(e){message('Collection: $e');}finally{if(mounted)setState(()=>busy=false);}}
 List<Widget> ledger(){final rows=sales.where((r)=>r.entries.where((e)=>e.key!='image_data').map((e)=>e.value).join(' ').toLowerCase().contains(search)).toList();return [heading('Customer ledger','Search customer or invoice • unknown payments excluded'),searchBox(),FilledButton(onPressed:()=>report('Customer statement',rows.map((r)=>[r['number'].toString(),r['customer'].toString(),(r['total'] as num).toStringAsFixed(2),outstanding(r)?.toStringAsFixed(2)??'Unknown']).toList(),['Invoice','Customer','Total INR','Due INR']),child:const Text('Export statement')),OutlinedButton(onPressed:()=>report('Outstanding report',rows.where((r)=>(outstanding(r)??0)>0).map((r)=>[r['number'].toString(),r['customer'].toString(),outstanding(r)!.toStringAsFixed(2)]).toList(),['Invoice','Customer','Due INR']),child:const Text('Outstanding report')),...rows.map((r)=>Card(child:Column(children:[ListTile(title:Text('${r['customer']} • ${r['number']}'),subtitle:Text('Due: ${outstanding(r)==null?'Unknown':money(outstanding(r)!)}'),trailing:TextButton(onPressed:busy||(outstanding(r)??0)<=0?null:()=>collect(r),child:const Text('Collect'))),...collections.where((c)=>c['sale']==r['id']).map((c)=>ListTile(title:Text('Received ${money(c['amount'] as num)}'),subtitle:Text('${c['date']} • ${c['mode']}'),onTap:()=>report('Payment receipt ${c['id']}',[[r['number'].toString(),r['customer'].toString(),c['date'].toString(),c['mode'].toString(),(c['amount'] as num).toStringAsFixed(2)]],['Invoice','Customer','Date','Mode','INR']))) ])))];}
 Future<void> editInvoice(Map<String,Object?> r) async {
 if(busy)return;
 setState(()=>busy=true);
 try {
 final oldLines=await widget.db.query('lines',where:'sale=?',whereArgs:[r['id']]);
 final logs=await widget.db.query('invoice_edits',where:'sale=?',whereArgs:[r['id']],orderBy:'id DESC');
 if(!mounted)return;
 final result=await Navigator.push<Map<String,Object?>>(context,MaterialPageRoute(builder:(_)=>InvoiceEditor(sale:r,lines:oldLines,products:products,received:collected(r),logs:logs)));
 if(result==null)return;
 final next=List<Map<String,Object?>>.from(result['lines'] as List);
 final previous=List<Map<String,Object?>>.from(result['previous'] as List);
 final data=Map<String,Object?>.from(result['sale'] as Map);
 await widget.db.transaction((tx) async {
 final current=(await tx.query('sales',where:'id=?',whereArgs:[r['id']])).single;
 final currentLines=await tx.query('lines',where:'sale=?',whereArgs:[r['id']]);
 if(jsonEncode(current)!=jsonEncode(r)||jsonEncode(currentLines)!=jsonEncode(oldLines))throw Exception('Invoice changed; reopen editor');
 final receipts=await tx.query('collections',where:'sale=?',whereArgs:[r['id']]);
 final received=receipts.fold<double>(0,(a,c)=>a+(c['amount'] as num).toDouble());
 if(data['paid']!=null&&(data['paid'] as num)+received>(data['total'] as num)+0.000001)throw Exception('Total below payments already received');
 final delta=<int,int>{};
 for(final line in previous){final id=line['product_id'] as int?;if(id!=null)delta[id]=(delta[id]??0)+(line['qty'] as int);}
 for(final line in next){final id=line['product_id'] as int?;if(id!=null)delta[id]=(delta[id]??0)-(line['qty'] as int);}
 for(final e in delta.entries){if(e.value==0)continue;final n=await tx.rawUpdate('UPDATE products SET qty=qty+? WHERE id=? AND qty+?>=0',[e.value,e.key,e.value]);if(n!=1)throw Exception('Product missing or insufficient stock');await tx.rawUpdate("UPDATE stock_movements SET reason=? WHERE id=(SELECT MAX(id) FROM stock_movements WHERE product_id=?)",['Invoice edit',e.key]);}
 await tx.insert('invoice_edits',{'sale':r['id'],'date':DateTime.now().toIso8601String(),'snapshot':jsonEncode({'sale':current,'lines':currentLines,'collections':receipts})});
 await tx.update('sales',data,where:'id=?',whereArgs:[r['id']]);
 await tx.delete('lines',where:'sale=?',whereArgs:[r['id']]);
 for(final line in next){await tx.insert('lines',{...line,'sale':r['id']}..remove('id'));}await validateSerials(tx);
 });
 cart.clear();await refresh();message('Invoice updated');
 }catch(e){message('Edit failed: $e');}finally{if(mounted)setState(()=>busy=false);}
 }
 Future<void> invoice(Map<String,Object?> r) async {
 try {
 final lines=await widget.db.query('lines',where:'sale=?',whereArgs:[r['id']]);
 final subtotal=lines.fold<double>(0,(a,l)=>a+(l['price'] as num)*(l['qty'] as num));
 final grand=(r['total'] as num).toDouble();
 final paid=r['paid']==null?null:(r['paid'] as num).toDouble()+collected(r);
 final due=paid==null?null:max(0.0,grand-paid);
 final doc=pw.Document();
 final template=(int.tryParse(widget.settings['invoice_template']??'0')??0).clamp(0,5).toInt();
 final accent=[PdfColors.black,PdfColors.grey800,PdfColors.grey700,PdfColors.blue900,PdfColor.fromInt(0xff94742c),PdfColors.teal800][template];
 final classic=template==0||template==2;
 final ink=classic?PdfColors.black:PdfColors.white;
 final band=classic?PdfColors.grey200:accent;
 final logo=pw.MemoryImage((await rootBundle.load('assets/logo.png')).buffer.asUint8List());
 final cfg=widget.settings;
 final upi=cfg['upi']??'';
 final qr=Uri(scheme:'upi',host:'pay',queryParameters:{'pa':upi,'pn':cfg['business']??'MR Vision Tech',if(due!=null)'am':due.toStringAsFixed(2),'cu':'INR','tn':'Invoice ${r['number']}'}).toString();
 String amount(num n)=>NumberFormat('#,##,##0.00','en_IN').format(n);
 final taxes=<double,double>{};
 for(final l in lines){final rate=(l['gst'] as num).toDouble();taxes[rate]=(taxes[rate]??0)+(l['price'] as num)*(l['qty'] as num)*rate/100;}
 final gst=taxes.keys.any((v)=>v>0)||(cfg['gstin']??'').trim().isNotEmpty;
 final business=cfg['business']??'MR Vision Tech';
 final date=DateFormat('dd MMM yyyy').format(DateTime.parse(r['date'] as String));
 final matches=await widget.db.query('clients',where:'name=?',whereArgs:[r['customer']]);
 final customer=matches.length==1?matches.first:<String,Object?>{};
 final terms=(cfg['terms']??'').replaceFirst(RegExp(r'^\s*terms\s*(?:&|and)\s*conditions\s*:?\s*',caseSensitive:false),'').trim();
 pw.Widget label(String t)=>pw.Text(t,style:pw.TextStyle(fontSize:9,color:accent,fontWeight:pw.FontWeight.bold));
 pw.Widget company({bool centered=false})=>pw.Column(crossAxisAlignment:centered?pw.CrossAxisAlignment.center:pw.CrossAxisAlignment.start,children:[pw.Text(business,style:pw.TextStyle(fontSize:18,color:accent,fontWeight:pw.FontWeight.bold)),pw.Text(cfg['address']??'',style:const pw.TextStyle(fontSize:9)),pw.Text(cfg['phone']??'',style:const pw.TextStyle(fontSize:9)),if((cfg['gstin']??'').isNotEmpty)pw.Text('GSTIN: ${cfg['gstin']}')]);
 pw.Widget meta()=>pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.end,children:[pw.Text('INVOICE',style:pw.TextStyle(fontSize:13,color:accent,fontWeight:pw.FontWeight.bold)),pw.Text('${r['number']}'),pw.Text(date)]);
 pw.Widget header(){
 if(template==4)return pw.Column(children:[pw.Image(logo,width:65,height:65),company(centered:true),pw.Divider(color:accent,thickness:2),pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[label('INVOICE'),pw.Text('${r['number']}  |  $date')])]);
 if(template==1)return pw.Column(children:[pw.Row(children:[pw.Image(logo,width:65,height:65),pw.SizedBox(width:12),pw.Expanded(child:company())]),pw.Container(color:band,padding:const pw.EdgeInsets.all(10),child:pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[pw.Text('INVOICE',style:pw.TextStyle(color:ink,fontWeight:pw.FontWeight.bold)),pw.Text('${r['number']}  |  $date',style:pw.TextStyle(color:ink))]))]);
 if(template==5)return pw.Column(children:[pw.Row(children:[pw.Expanded(child:company()),pw.Image(logo,width:68,height:68)]),pw.Divider(color:accent,thickness:3),pw.Align(alignment:pw.Alignment.centerLeft,child:pw.Text('INVOICE  /  ${r['number']}  /  $date',style:pw.TextStyle(color:accent,fontWeight:pw.FontWeight.bold)))]);
 return pw.Column(children:[pw.Row(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[pw.Image(logo,width:template==2?48:72,height:template==2?48:72),pw.SizedBox(width:12),pw.Expanded(child:company()),meta()]),pw.Divider(color:accent,thickness:template==3?4:1)]);
 }
 pw.Widget bill()=>pw.Container(width:double.infinity,padding:const pw.EdgeInsets.all(12),decoration:pw.BoxDecoration(border:pw.Border.all(color:PdfColors.grey400)),child:pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[label('BILL TO'),pw.SizedBox(height:5),pw.Text('${r['customer']}',style:pw.TextStyle(fontSize:9,fontWeight:pw.FontWeight.bold)),if((customer['phone']??'').toString().isNotEmpty)pw.Text('Mobile: ${customer['phone']}'),if((customer['address']??'').toString().isNotEmpty)pw.Text('${customer['address']}')]));
 pw.Widget summary(String title,String value)=>pw.Padding(padding:const pw.EdgeInsets.all(7),child:pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[pw.Text(title),pw.Text(value)]));
 pw.Widget total()=>pw.Container(decoration:pw.BoxDecoration(border:pw.Border.all(color:PdfColors.grey400)),child:pw.Column(children:[summary('Subtotal',amount(subtotal)),if(gst)summary('GST',amount(grand-subtotal)),pw.Container(color:band,padding:const pw.EdgeInsets.all(12),child:pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[pw.Text('TOTAL (INR)',style:pw.TextStyle(color:ink,fontWeight:pw.FontWeight.bold)),pw.Text(amount(grand),style:pw.TextStyle(color:ink,fontSize:12,fontWeight:pw.FontWeight.bold))]))]));
 pw.Widget payment()=>pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[if(upi.contains('@')&&(due==null||due>0)&&grand>0&&cfg['qr']!='0')pw.Row(children:[pw.BarcodeWidget(barcode:pw.Barcode.qrCode(),data:qr,width:76,height:76),pw.SizedBox(width:8),pw.Expanded(child:pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[label('SCAN TO PAY'),pw.Text(upi),pw.Text('Verify outstanding amount before payment',style:const pw.TextStyle(fontSize:9))]))])]);
 pw.Widget taxSummary()=>pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[if(gst)...[label('GST SUMMARY'),...taxes.entries.map((e)=>pw.Text('${e.key.toStringAsFixed(2)}% : INR ${amount(e.value)}'))]]);
 doc.addPage(pw.MultiPage(pageFormat:PdfPageFormat.a4,theme:pw.ThemeData(defaultTextStyle:const pw.TextStyle(fontSize:9)),margin:const pw.EdgeInsets.all(10*PdfPageFormat.mm),header:(_)=>header(),footer:(ctx)=>pw.Column(children:[pw.Divider(color:accent),pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[pw.Text('Thank you for your business.'),pw.Text('Page ${ctx.pageNumber} / ${ctx.pagesCount}')])]),build:(_)=>[
 pw.SizedBox(height:12),bill(),pw.SizedBox(height:16),
 pw.TableHelper.fromTextArray(headerDecoration:pw.BoxDecoration(color:band),headerStyle:pw.TextStyle(color:ink,fontSize:9,fontWeight:pw.FontWeight.bold),cellStyle:const pw.TextStyle(fontSize:8.5),cellPadding:pw.EdgeInsets.all(template==2?4:6),cellAlignments:{0:pw.Alignment.center,2:pw.Alignment.centerRight,3:pw.Alignment.centerRight,4:pw.Alignment.centerRight,5:pw.Alignment.centerRight,6:pw.Alignment.centerRight,7:pw.Alignment.centerRight},columnWidths:{0:const pw.FlexColumnWidth(.55),1:const pw.FlexColumnWidth(3),2:const pw.FlexColumnWidth(.65)},headers:['#','Description','Qty','Rate',if(gst)...['Taxable','GST %','GST'],'Total'],data:List.generate(lines.length,(i){final l=lines[i];final base=(l['price'] as num)*(l['qty'] as num);final tax=base*(l['gst'] as num)/100;return [i+1,[l['name'].toString(),if((l['serials']??'').toString().trim().isNotEmpty) 'S/N: ${l['serials']}',if((l['warranty_snapshot']??'').toString().trim().isNotEmpty) 'Warranty: ${l['warranty_snapshot']}'].join('\n'),l['qty'],amount(l['price'] as num),if(gst)...[amount(base),l['gst'],amount(tax)],amount(base+tax)];})),
 pw.SizedBox(height:16),
 if(template==4)...[total(),pw.SizedBox(height:12),taxSummary(),payment()]else if(template==5)...[pw.Row(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[pw.Expanded(child:total()),pw.SizedBox(width:20),pw.Expanded(child:payment())]),taxSummary()]else ...[pw.Row(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[pw.Expanded(child:template==3?payment():taxSummary()),pw.SizedBox(width:16),pw.Expanded(child:total())]),pw.SizedBox(height:12),if(template==3)taxSummary()else payment()],
 pw.Text('Amount in words: ${amountWords(grand)}'),pw.SizedBox(height:10),summary('Payment mode',r['payment_mode']?.toString()??'Not recorded'),if(paid!=null)...[summary('Paid amount',amount(paid)),summary('Due amount',amount(due!))],if(terms.isNotEmpty)...[pw.SizedBox(height:16),label('TERMS & CONDITIONS'),pw.SizedBox(height:6),pw.Text(terms,style:const pw.TextStyle(fontSize:7.5))],pw.SizedBox(height:20),pw.Align(alignment:pw.Alignment.centerRight,child:pw.Container(width:180,padding:const pw.EdgeInsets.all(10),decoration:pw.BoxDecoration(border:pw.Border.all(color:PdfColors.grey400)),child:pw.Column(children:[pw.Text('For $business'),pw.SizedBox(height:30),pw.Divider(color:accent),pw.Text('Authorized Signatory')])))]));
 final bytes=await doc.save();if(!mounted)return;
 await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>Scaffold(appBar:AppBar(title:Text('${r['number']}')),body:PdfPreview(build:(_) async=>bytes,pdfFileName:'${r['number']}.pdf',canChangePageFormat:false,canChangeOrientation:false))));
 }catch(e){message('PDF error: $e');}}
 Widget heading(String title,String sub)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight:FontWeight.w800)),const SizedBox(height:5),Text(sub,style:Theme.of(context).textTheme.bodyMedium)]);
 Widget metric(String title,String value,IconData icon,Color color)=>Card(elevation:0,child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[CircleAvatar(radius:18,backgroundColor:color.withValues(alpha:.13),foregroundColor:color,child:Icon(icon,size:20)),const SizedBox(height:6),Expanded(child:Align(alignment:Alignment.centerLeft,child:Text(title,maxLines:2,overflow:TextOverflow.ellipsis))),const SizedBox(height:4),FittedBox(fit:BoxFit.scaleDown,child:Text(value,style:const TextStyle(fontSize:23,fontWeight:FontWeight.bold)))])));
 Widget saleTile(Map<String,Object?> r)=>Card(elevation:0,child:ListTile(leading:const CircleAvatar(child:Icon(Icons.receipt_long_outlined)),title:Text('${r['number']}'),subtitle:Text('${r['customer']} • ${DateFormat('dd MMM, HH:mm').format(DateTime.parse(r['date'] as String))}'),trailing:Row(mainAxisSize:MainAxisSize.min,children:[Text(money(r['total'] as num)),IconButton(tooltip:'Edit invoice',onPressed:busy?null:()=>editInvoice(r),icon:const Icon(Icons.edit_outlined))]),onTap:()=>invoice(r),onLongPress:busy?null:()=>editInvoice(r)));
 List<Widget> dashboard(){final today=DateTime.now().toIso8601String().substring(0,10);final daily=sales.where((r)=>(r['date'] as String).startsWith(today));return [heading('Business overview','Your business, at a glance'),const SizedBox(height:18),Container(padding:const EdgeInsets.all(24),decoration:BoxDecoration(gradient:LinearGradient(colors:[Theme.of(context).colorScheme.primary,Theme.of(context).colorScheme.primary.withValues(alpha:.8)]),borderRadius:BorderRadius.circular(24)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('TODAY’S SALES',style:TextStyle(color:Colors.white70,letterSpacing:1.5)),const SizedBox(height:12),Text(money(daily.fold<num>(0,(s,r)=>s+(r['total'] as num))),style:const TextStyle(color:Colors.white,fontSize:32,fontWeight:FontWeight.bold)),const SizedBox(height:16),FilledButton.tonalIcon(onPressed:()=>go(2),icon:const Icon(Icons.add),label:const Text('New invoice'))])),const SizedBox(height:12),GridView.count(crossAxisCount:2,shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),mainAxisExtent:145,crossAxisSpacing:10,mainAxisSpacing:8,children:[metric('Cash received',money(daily.where((r)=>r['payment_mode']=='Cash').fold<num>(0,(a,r)=>a+(r['paid'] as num? ?? 0))+collections.where((r)=>r['mode']=='Cash'&&r['date'].toString().startsWith(today)).fold<num>(0,(a,r)=>a+(r['amount'] as num))),Icons.payments,Colors.green),metric('Known outstanding',money(sales.fold<num>(0,(a,r)=>a+(outstanding(r)??0))),Icons.wallet,Colors.orange),metric('Invoices today','${daily.length}',Icons.receipt_long,Colors.blue),metric('Products','${products.length}',Icons.inventory_2,Colors.deepPurple),metric('Low stock','${products.where((r)=>(r['qty'] as int)<=((r['min_stock'] as int?)??5)).length}',Icons.warning_amber,Colors.orange),metric('Customers','${clients.length}',Icons.people,Colors.teal)]),const SizedBox(height:12),Wrap(spacing:8,runSpacing:8,children:[FilledButton.tonal(onPressed:()=>go(1),child:const Text('Stock')),FilledButton.tonal(onPressed:()=>go(5),child:const Text('Customers')),FilledButton.tonal(onPressed:()=>go(6),child:const Text('Collect due'))]),const SizedBox(height:20),metricWide(),const SizedBox(height:16),weeklyChart(),const SizedBox(height:16),Text('Recent invoices',style:Theme.of(context).textTheme.titleLarge),if(sales.isEmpty)const Padding(padding:EdgeInsets.all(20),child:Text('No invoices yet')),...sales.take(5).map(saleTile)];}
 Widget metricWide()=>Card(child:Padding(padding:const EdgeInsets.all(18),child:Row(children:[const CircleAvatar(child:Icon(Icons.account_balance_wallet_outlined)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Stock value • selling price, ex GST'),Text(money(products.fold<num>(0,(a,r)=>a+(r['price'] as num)*(r['qty'] as num))),style:Theme.of(context).textTheme.titleLarge)]))])));
 Widget weeklyChart(){final now=DateTime.now();final days=List.generate(7,(i)=>DateTime(now.year,now.month,now.day-6+i));final values=days.map((d)=>sales.where((r)=>(r['date'] as String).startsWith(DateFormat('yyyy-MM-dd').format(d))).fold<double>(0,(a,r)=>a+(r['total'] as num).toDouble())).toList();final peak=values.fold<double>(1,(a,b)=>max(a,b));return Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Sales • last 7 days',style:Theme.of(context).textTheme.titleMedium),Text(money(values.fold<double>(0,(a,b)=>a+b))),const SizedBox(height:16),Row(crossAxisAlignment:CrossAxisAlignment.end,children:List.generate(7,(i)=>Expanded(child:Column(children:[Tooltip(message:money(values[i]),child:Container(height:4+100*values[i]/peak,width:20,decoration:BoxDecoration(color:Theme.of(context).colorScheme.primary,borderRadius:BorderRadius.circular(6)))),const SizedBox(height:8),Text(DateFormat('E').format(days[i]),style:const TextStyle(fontSize:11))]))))])));}
 Widget searchBox()=>TextField(key:ValueKey(tab),onChanged:(s)=>setState(()=>search=s.toLowerCase()),decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:'Search records',filled:true,border:OutlineInputBorder(borderRadius:BorderRadius.circular(18),borderSide:BorderSide.none)));
 List<Widget> records(bool product){final rows=product?products:clients;final filtered=rows.where((r)=>r.values.join(' ').toLowerCase().contains(search)&&(!product||((category=='All'||r['category']==category)&&(brandFilter==null||(r['brand']??'').toString()==brandFilter)&&(!lowOnly||(r['qty'] as int)<=((r['min_stock'] as int?)??5)))));return [heading(product?'Inventory':'Customers',product?'Manage products and stock • hold a product to print barcode':'Manage customer relationships'),const SizedBox(height:16),searchBox(),if(product) OutlinedButton.icon(onPressed:()=>scanProduct(billing:false),icon:const Icon(Icons.qr_code_scanner),label:const Text('Scan product')),if(product) OutlinedButton.icon(onPressed:() async {await Navigator.push<void>(context,MaterialPageRoute(builder:(_)=>CatalogPage(db:widget.db)));if(mounted){setState((){category='All';brandFilter=null;});await refresh();}},icon:const Icon(Icons.category),label:const Text('Manage categories & brands')),if(product) Wrap(spacing:8,children:[DropdownButton<String>(value:brandFilter, hint:const Text('All brands'),items:[const DropdownMenuItem<String>(value:null,child:Text('All brands')),...{...products.map((r)=>(r['brand']??'').toString()),if(brandFilter!=null)brandFilter!}.map((v)=>DropdownMenuItem(value:v,child:Text(v.isEmpty?'Unbranded':v)))],onChanged:(v)=>setState(()=>brandFilter=v)),FilterChip(label:const Text('Low stock'),selected:lowOnly,onSelected:(v)=>setState(()=>lowOnly=v)),DropdownButton<String>(value:category,items:{'All',...products.map((r)=>(r['category']??'General').toString()),category}.map((v)=>DropdownMenuItem(value:v,child:Text(v.isEmpty?'Uncategorized':v))).toList(),onChanged:(v)=>setState(()=>category=v??'All'))]),const SizedBox(height:12),FilledButton.icon(onPressed:()=>edit(product),icon:const Icon(Icons.add),label:Text(product?'Add product':'Add customer')),if(filtered.isEmpty)const Padding(padding:EdgeInsets.all(32),child:Center(child:Text('No records found'))),...filtered.map((r)=>Card(elevation:0,child:ListTile(leading:product?productPhoto(r['image_data']?.toString()??'',48):const CircleAvatar(child:Icon(Icons.person_outline)),title:Text('${r['name']}'),subtitle:Text(product?'${r['code']} • ${r['qty']} in stock • ${r['category']??'General'}':'${r['phone']} • ${r['address']}'),onTap:()=>edit(product,r),onLongPress:product?()=>barcodeLabel(r):null,trailing:product?Column(mainAxisAlignment:MainAxisAlignment.center,children:[Text(money(r['price'] as num)),if((r['qty'] as int)<=((r['min_stock'] as int?)??5))const Text('LOW STOCK',style:TextStyle(color:Colors.orange,fontSize:10,fontWeight:FontWeight.bold))]):const Icon(Icons.edit_outlined))))];}
 List<Widget> pos()=>[heading('New sale','Select products and review your cart'),const SizedBox(height:16),DropdownButtonFormField<int>(value:client,decoration:const InputDecoration(labelText:'Customer',border:OutlineInputBorder()),items:[const DropdownMenuItem<int>(value:null,child:Text('Walk-in customer')),...clients.map((r)=>DropdownMenuItem<int>(value:r['id'] as int,child:Text('${r['name']}')))],onChanged:busy?null:(v)=>setState(()=>client=v)),const SizedBox(height:12),searchBox(),OutlinedButton.icon(onPressed:busy?null:()=>scanProduct(billing:true),icon:const Icon(Icons.qr_code_scanner),label:const Text('Scan to cart')),if(products.isEmpty)TextButton(onPressed:()=>go(1),child:const Text('Add products first')),...products.where((r)=>r.values.join(' ').toLowerCase().contains(search)).map((r){final id=r['id'] as int;final q=cart[id]??0;return Card(elevation:0,child:ListTile(title:Text('${r['name']}'),subtitle:Text('${money(r['price'] as num)} + ${r['gst']}% GST'),trailing:Row(mainAxisSize:MainAxisSize.min,children:[IconButton(onPressed:busy||q==0?null:()=>setState(()=>cart[id]=q-1),icon:const Icon(Icons.remove_circle_outline)),Text('$q'),IconButton(onPressed:busy||q>=(r['qty'] as int)?null:()=>setState(()=>cart[id]=q+1),icon:const Icon(Icons.add_circle))])));}),const SizedBox(height:16),Text('Cart total  ${money(cartTotal)}',style:Theme.of(context).textTheme.titleLarge),FilledButton.icon(onPressed:busy||!cart.values.any((q)=>q>0)?null:checkout,icon:const Icon(Icons.check),label:const Text('Save invoice'))];
 @override Widget build(BuildContext context){final pages=[dashboard,()=>records(true),pos,()=>[heading('Invoices','Search, preview or share invoices'),const SizedBox(height:12),searchBox(),...sales.where((r)=>r.values.join(' ').toLowerCase().contains(search)).map(saleTile)],()=>[heading('Settings','MR Vision Tech'),ListTile(leading:const Icon(Icons.people_outline),title:const Text('Customers'),onTap:()=>go(5)),ListTile(leading:const Icon(Icons.account_balance_wallet_outlined),title:const Text('Customer Ledger & Due'),onTap:()=>go(6)),ListTile(leading:const Icon(Icons.palette_outlined),title:const Text('Appearance & Themes'),onTap:()=>Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>ThemePage(settings:widget.settings,save:widget.save)))),ListTile(leading:const Icon(Icons.business),title:const Text('Business & Invoice Settings'),onTap:()=>Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>ConfigPage(settings:widget.settings,save:widget.save)))),ListTile(leading:const Icon(Icons.description_outlined),title:const Text('Invoice Templates (A4)'),onTap:() async {final choice=await showDialog<int>(context:context,builder:(ctx)=>SimpleDialog(title:const Text('Select A4 template'),children:List.generate(6,(i)=>SimpleDialogOption(onPressed:()=>Navigator.pop(ctx,i),child:Text(['Classic Monochrome','Tally Professional','MR Vision Compact','Corporate Blue','Premium Gold','Modern Premium'][i])))));if(choice!=null)await widget.save('invoice_template',choice.toString());}),ListTile(leading:const Icon(Icons.qr_code),title:const Text('Serial & Warranty Lookup'),onTap:()=>Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>SerialLookup(db:widget.db)))),ListTile(leading:const Icon(Icons.inventory),title:const Text('Stock Management'),onTap:() async {await Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>StockManagement(db:widget.db)));cart.clear();await refresh();}),ListTile(leading:const Icon(Icons.local_shipping_outlined),title:const Text('Purchase & Suppliers'),onTap:() async {await Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>PurchasePage(db:widget.db)));cart.clear();await refresh();}),ListTile(leading:const Icon(Icons.backup_outlined),title:const Text('Backup & Restore'),subtitle:const Text('Export or restore business data'),onTap:() async {await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>BackupPage(db:widget.db,onRestored:() async {cart.clear();client=null;category='All';brandFilter=null;lowOnly=false;await widget.reloadSettings();await refresh();})));}),SwitchListTile(title:const Text('Dark mode'),value:widget.dark,onChanged:(_)=>widget.toggle()),ListTile(leading:const Icon(Icons.info_outline),title:const Text('About ERP'),subtitle:const Text('MR Vision Tech • Offline edition 3.5.1'),onTap:()=>Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>const DeveloperAboutPage())))],()=>records(false),ledger];return PopScope<Object?>(canPop:false,onPopInvokedWithResult:(didPop,result){if(!didPop)back();},child:Scaffold(appBar:AppBar(backgroundColor:Theme.of(context).colorScheme.primary,foregroundColor:Theme.of(context).colorScheme.onPrimary,title:Row(children:[ClipRRect(borderRadius:BorderRadius.circular(8),child:Image.asset('assets/logo.png',width:40,height:40)),const SizedBox(width:12),const Text('MR Vision Tech',style:TextStyle(fontWeight:FontWeight.bold))]),actions:[IconButton(onPressed:()=>go(5),icon:const Icon(Icons.people_outline),tooltip:'Customers')]),body:SafeArea(child:ListView(key:ValueKey(tab),padding:const EdgeInsets.all(16),children:pages[tab]())),bottomNavigationBar:NavigationBar(selectedIndex:tab>=5?4:tab,onDestinationSelected:go,destinations:const [NavigationDestination(icon:Icon(Icons.dashboard_outlined),label:'Home'),NavigationDestination(icon:Icon(Icons.inventory_2_outlined),label:'Stock'),NavigationDestination(icon:Icon(Icons.shopping_cart_outlined),label:'POS'),NavigationDestination(icon:Icon(Icons.receipt_long_outlined),label:'Sales'),NavigationDestination(icon:Icon(Icons.settings_outlined),label:'More')])));}
}

class _RecordDialog extends StatefulWidget {
 final bool product; final Map<String,Object?>? record;
 final List<String> categories,brands; const _RecordDialog({required this.product,this.record,required this.categories,required this.brands});
 @override State<_RecordDialog> createState()=>_RecordDialogState();
}
class _RecordDialogState extends State<_RecordDialog> {
 late final List<TextEditingController> cs;
 @override void initState(){super.initState();final keys=widget.product?['code','name','price','qty','gst','cost','category','barcode','hsn','unit','brand','warranty','min_stock','image_data']:['name','phone','address'];cs=keys.map((k)=>TextEditingController(text:widget.record?[k]?.toString()??'')).toList();if(widget.product){if(cs[9].text.isEmpty)cs[9].text='PCS';if(cs[12].text.isEmpty)cs[12].text='5';}if(widget.product&&widget.record==null){cs[0].text='MR-GEN-${Random.secure().nextInt(0x10000).toRadixString(16).padLeft(4,'0').toUpperCase()}';cs[3].text='0';cs[4].text='0';cs[6].text='General';cs[9].text='PCS';cs[12].text='5';}}
 @override void dispose(){for(final c in cs){c.dispose();}super.dispose();}
 Widget field(String label,TextEditingController c,{bool numeric=false})=>Padding(padding:const EdgeInsets.only(bottom:14),child:TextField(controller:c,keyboardType:numeric?const TextInputType.numberWithOptions(decimal:true):TextInputType.text,decoration:InputDecoration(labelText:label,border:OutlineInputBorder(borderRadius:BorderRadius.circular(14)))));
 @override Widget build(BuildContext context)=>Scaffold(
 appBar:AppBar(title:Text(widget.record==null?(widget.product?'Add product':'Add customer'):(widget.product?'Edit product':'Edit customer'))),
 body:SafeArea(child:ListView(padding:const EdgeInsets.all(20),children:[Text(widget.product?'Product information':'Customer information',style:Theme.of(context).textTheme.titleLarge),const SizedBox(height:16),...List.generate(widget.product?13:cs.length,(i)=>field((widget.product?['Item code','Product name','Selling price before GST','Stock quantity','GST %','Purchase price (optional)','Category','Barcode','HSN/SAC','Unit (PCS, MTR, BOX, JOB)','Brand','Warranty (e.g. 12 months)','Minimum stock']:['Name','Phone','Address'])[i],cs[i],numeric:widget.product&&((i>=2&&i<=5)||i==12))),if(widget.product)...[Center(child:productPhoto(cs[13].text,120)),Wrap(spacing:8,children:[OutlinedButton.icon(onPressed:() async {try{final picked=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['png','jpg','jpeg','webp'],withData:true);if(picked==null||!mounted)return;final bytes=picked.files.single.bytes;if(bytes==null||bytes.length>1024*1024)throw Exception('Choose an image under 1 MB');final codec=await instantiateImageCodec(bytes,targetWidth:320);final frame=await codec.getNextFrame();frame.image.dispose();codec.dispose();if(mounted)setState(()=>cs[13].text=base64Encode(bytes));}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}},icon:const Icon(Icons.image),label:const Text('Choose product image')),TextButton(onPressed:()=>setState(()=>cs[13].clear()),child:const Text('Remove image'))]),for(final entry in {6:widget.categories,10:widget.brands}.entries) Wrap(spacing:6,children:entry.value.where((v)=>v.isNotEmpty).map((v)=>ActionChip(label:Text(v),onPressed:()=>setState(()=>cs[entry.key].text=v))).toList())],if(widget.product)Wrap(spacing:8,children:[OutlinedButton.icon(onPressed:() async {final code=await Navigator.push<String>(context,MaterialPageRoute(builder:(_)=>const BarcodeScanPage()));if(mounted&&code!=null)cs[7].text=code;},icon:const Icon(Icons.qr_code_scanner),label:const Text('Scan barcode')),OutlinedButton(onPressed:(){cs[7].text=cs[0].text.trim();},child:const Text('Use item code as barcode'))]),if(widget.product&&widget.record==null)OutlinedButton(onPressed:(){final cat=cs[6].text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'),'');cs[0].text='MR-${cat.isEmpty?'GEN':cat.substring(0,min(3,cat.length))}-${Random.secure().nextInt(65536).toRadixString(16).padLeft(4,'0').toUpperCase()}';},child:const Text('Generate category item code')),FilledButton.icon(onPressed:()=>Navigator.of(context).pop(cs.map((c)=>c.text.trim()).toList()),icon:const Icon(Icons.save_outlined),label:const Text('Save record'))])));
}

class ThemePage extends StatefulWidget {
 final Map<String,String> settings; final Future<void> Function(String,String) save;
 const ThemePage({super.key,required this.settings,required this.save});
 @override State<ThemePage> createState()=>_ThemePageState();
}
class _ThemePageState extends State<ThemePage>{
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Appearance & Themes')),body:ListView(children:List.generate(8,(i)=>ListTile(leading:CircleAvatar(backgroundColor:Color(_ERPState.colors[i])),title:Text(_ERPState.names[i]),trailing:widget.settings['theme']==i.toString()?const Icon(Icons.check):null,onTap:() async {await widget.save('theme',i.toString());if(mounted)setState((){});} ))));
}
class ConfigPage extends StatefulWidget {
 final Map<String,String> settings; final Future<void> Function(String,String) save;
 const ConfigPage({super.key,required this.settings,required this.save});
 @override State<ConfigPage> createState()=>_ConfigPageState();
}
class _ConfigPageState extends State<ConfigPage>{
 final keys=['business','address','phone','gstin','upi','terms'];
 final labels=['Business name','Business address','Phone','GSTIN','UPI ID','Terms & Conditions (English)'];
 late final List<TextEditingController> cs; late bool qr;
 @override void initState(){super.initState();cs=keys.map((k)=>TextEditingController(text:widget.settings[k]??(k=='business'?'MR Vision Tech':''))).toList();qr=widget.settings['qr']!='0';}
 @override void dispose(){for(final c in cs){c.dispose();}super.dispose();}
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Business & Invoice Settings')),body:ListView(padding:const EdgeInsets.all(16),children:[...List.generate(keys.length,(i)=>Padding(padding:const EdgeInsets.only(bottom:12),child:TextField(controller:cs[i],maxLines:i==5?6:1,decoration:InputDecoration(labelText:labels[i],border:const OutlineInputBorder())))),SwitchListTile(title:const Text('Show UPI QR on invoice'),value:qr,onChanged:(v)=>setState(()=>qr=v)),const Text('QR uses invoice total; payment is not verified automatically.'),FilledButton(onPressed:() async {for(var i=0;i<keys.length;i++){await widget.save(keys[i],cs[i].text.trim());}await widget.save('qr',qr?'1':'0');if(context.mounted)Navigator.pop(context);},child:const Text('Save settings'))]));
}

class DeveloperAboutPage extends StatelessWidget {
 const DeveloperAboutPage({super.key});
 @override Widget build(BuildContext context) {
  final colors=Theme.of(context).colorScheme;
  return Scaffold(appBar:AppBar(title:const Text('About ERP')),body:SafeArea(child:ListView(padding:const EdgeInsets.all(24),children:[
   Center(child:CircleAvatar(radius:64,backgroundImage:const AssetImage('assets/developer.jpg'))),
   const SizedBox(height:16),
   Text('Rashidur Rahman',textAlign:TextAlign.center,style:Theme.of(context).textTheme.headlineSmall),
   const Text('Software Developer',textAlign:TextAlign.center),
   const SizedBox(height:24),
   Card(child:Column(children:[
    ListTile(leading:Icon(Icons.phone,color:colors.primary),title:const Text('Mobile'),subtitle:const SelectableText('9153330300')),
    const Divider(height:1),
    ListTile(leading:Icon(Icons.email_outlined,color:colors.primary),title:const Text('Email'),subtitle:const SelectableText('me@rashidur.com')),
   ])),
   const SizedBox(height:24),
   Center(child:Image.asset('assets/logo.png',width:64,height:64)),
   const SizedBox(height:8),
   const Text('MR Vision Tech • Offline Edition 3.4.4',textAlign:TextAlign.center),
   const SizedBox(height:12),
   const Text('Developed by MR VisionTech: Rashidur Rahman',textAlign:TextAlign.center),
   const Text('© 2026 MR Vision Tech',textAlign:TextAlign.center),
  ])));
 }
}


class BackupPage extends StatefulWidget {
  final Database db;
  final Future<void> Function() onRestored;
  const BackupPage({super.key, required this.db, required this.onRestored});
  @override State<BackupPage> createState()=>_BackupPageState();
}
class _BackupPageState extends State<BackupPage> {
  static const columns=<String,List<String>>{
    'products':['id','code','name','price','qty','gst','cost','category','barcode','hsn','unit','brand','warranty','min_stock','image_data'],
    'clients':['id','name','phone','address'],
    'sales':['id','number','date','customer','total','paid','payment_mode'],
    'lines':['id','sale','name','qty','price','gst','cost','product_id','serials','warranty_snapshot'],
    'invoice_edits':['id','sale','date','snapshot'],
    'preferences':['k','v'],
    'collections':['id','sale','date','amount','mode'],
    'suppliers':['id','name','phone','address'],
    'purchases':['id','supplier_id','number','date','total','paid'],
    'purchase_lines':['id','purchase_id','product_id','name','qty','cost'],
    'supplier_events':['id','purchase_id','date','amount','mode','snapshot'],
    'stock_movements':['id','product_id','code','name','date','before_qty','after_qty','reason'],
  };
  bool busy=false;
  String status='';
  Future<void> run(Future<void> Function() action) async {
    if(busy)return;
    setState((){busy=true;status='';});
    try {await action();} catch(e){if(mounted)setState(()=>status='Operation failed: $e');}
    finally {if(mounted)setState(()=>busy=false);}
  }
  Future<bool> exportBackup() async {
    final tables=await widget.db.transaction((tx) async {
      final data=<String,Object?>{};
      for(final table in columns.keys){data[table]=await tx.query(table);}
      return data;
    });
    final bytes=Uint8List.fromList(utf8.encode(jsonEncode({'format':'mr-vision-tech-backup','schema':11,'created':DateTime.now().toIso8601String(),'tables':tables})));
    final path=await FilePicker.platform.saveFile(dialogTitle:'Save backup outside the app',fileName:'MR_Vision_Tech_Backup_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.json',type:FileType.custom,allowedExtensions:['json'],bytes:bytes);
    if(mounted)setState(()=>status=path==null?'Backup cancelled':'Backup exported. Keep this file in Downloads or another safe folder.');
    return path!=null;
  }
  Map<String,List<Map<String,Object?>>> validate(Object? raw){
    if(raw is! Map || raw['format']!='mr-vision-tech-backup'||![2,3,4,5,6,7,8,9,10,11].contains(raw['schema'])||raw['tables'] is! Map){throw const FormatException('Unsupported backup format');}
    final tables=raw['tables'] as Map;
    final result=<String,List<Map<String,Object?>>>{};
    for(final entry in columns.entries){
      final rows=((entry.key=='supplier_events'&&(raw['schema'] as int)<11)||(['suppliers','purchases','purchase_lines'].contains(entry.key)&&(raw['schema'] as int)<10)||(entry.key=='stock_movements'&&(raw['schema'] as int)<9)||(entry.key=='collections'&&[2,3].contains(raw['schema']))||(entry.key=='invoice_edits'&&(raw['schema'] as int)<5))?[]:tables[entry.key];
      if(rows is! List)throw FormatException('Missing table: ${entry.key}');
      final records=<Map<String,Object?>>[];
      final ids=<Object?>{};
      for(final original in rows){
        final migrated=entry.key=='products'&&(raw['schema'] as int)<6&&original is Map?{...original,'hsn':'','unit':'PCS','brand':'','warranty':'','min_stock':5}:entry.key=='lines'&&(raw['schema'] as int)<5&&original is Map?{...original,'product_id':null}:raw['schema']==2&&entry.key=='sales'&&original is Map?{...original,'paid':null,'payment_mode':null}:original;
        final legacy=entry.key=='lines'&&(raw['schema'] as int)<7&&migrated is Map?{...migrated,'serials':'','warranty_snapshot':''}:migrated;
        final row=entry.key=='products'&&(raw['schema'] as int)<8&&legacy is Map?{...legacy,'image_data':''}:legacy;
        if(row is! Map || row.length!=entry.value.length || !entry.value.every((c)=>row.containsKey(c)))throw FormatException('Invalid columns: ${entry.key}');
        final record=Map<String,Object?>.from(row);
        for(final c in entry.value){
          final v=record[c];
          if(c=='image_data'){if(v!=null&&(v is! String||v.length>1400000))throw const FormatException('Invalid product image');if(v is String&&v.isNotEmpty)base64Decode(v);}
          else if(c=='product_id'){if(v!=null&&(v is! int||v<1))throw const FormatException('Invalid product ID');}
          else if(['id','sale','supplier_id','purchase_id','qty','min_stock','before_qty','after_qty'].contains(c)){if(v is! int || v<(['qty','min_stock','before_qty','after_qty'].contains(c)?0:1))throw FormatException('Invalid $c');}
          else if(['price','gst','cost','total','paid','amount'].contains(c)){if(v==null&&['cost','paid'].contains(c))continue;if(v is! num||!v.isFinite||v<0||(c=='gst'&&v>100))throw FormatException('Invalid $c');}
          else if(v is! String && !(v==null&&['phone','address','category','barcode','payment_mode','hsn','unit','brand','warranty','serials','warranty_snapshot'].contains(c)))throw FormatException('Invalid $c');
        }
        if(entry.key=='sales'&&record['paid']!=null&&((record['paid'] as num)>(record['total'] as num)+0.005||!['Cash','UPI','Card','Bank Transfer','Credit'].contains(record['payment_mode'])))throw const FormatException('Invalid payment');
        if(!ids.add(record[entry.key=='preferences'?'k':'id']))throw const FormatException('Duplicate record');
        if(entry.key=='sales'&&DateTime.tryParse(record['date'] as String)==null)throw const FormatException('Invalid invoice date');
        records.add(record);
      }
      result[entry.key]=records;
    }
    final saleIds=result['sales']!.map((r)=>r['id']).toSet();
    if(result['invoice_edits']!.any((r)=>!saleIds.contains(r['sale'])))throw const FormatException('Invalid edit history');
    if(result['lines']!.any((r)=>!saleIds.contains(r['sale'])))throw const FormatException('Invoice lines without invoice');
    if(result['collections']!.any((r)=>!saleIds.contains(r['sale'])||(r['amount'] as num)<=0||DateTime.tryParse(r['date'] as String)==null||!['Cash','UPI','Card','Bank Transfer'].contains(r['mode'])))throw const FormatException('Invalid collection');
    for(final sale in result['sales']!){final sum=result['collections']!.where((r)=>r['sale']==sale['id']).fold<num>(0,(a,r)=>a+(r['amount'] as num));if(sum>0&&(sale['paid']==null||sum+(sale['paid'] as num)>(sale['total'] as num)+0.005))throw const FormatException('Invalid collection balance');}
    final supplierIds=result['suppliers']!.map((r)=>r['id']).toSet();
    final purchaseIds=result['purchases']!.map((r)=>r['id']).toSet();
    for(final r in result['purchase_lines']!){if(!purchaseIds.contains(r['purchase_id'])||r['product_id']==null||r['cost']==null||(r['qty'] as int)<=0)throw const FormatException('Invalid purchase line');}
    for(final r in result['purchases']!){final lines=result['purchase_lines']!.where((l)=>l['purchase_id']==r['id']);final total=lines.fold<num>(0,(a,l)=>a+(l['qty'] as int)*(l['cost'] as num));if(!supplierIds.contains(r['supplier_id'])||r['paid']==null||lines.isEmpty||DateTime.tryParse(r['date'] as String)==null||(r['paid'] as num)>(r['total'] as num)+0.005||(total-(r['total'] as num)).abs()>0.005)throw const FormatException('Invalid purchase');}
    for(final r in result['supplier_events']!){if(!purchaseIds.contains(r['purchase_id'])||DateTime.tryParse(r['date'] as String)==null||!['Payment','Return','Edit'].contains(r['mode']))throw const FormatException('Invalid supplier event');}
    checkSerialRows(result['lines']!);
    return result;
  }
  Future<void> restore() async {
    final picked=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['json'],withData:true);
    if(picked==null)return;
    final bytes=picked.files.single.bytes;
    if(bytes==null)throw const FormatException('Cannot read backup');
    final data=validate(jsonDecode(utf8.decode(bytes)));
    if(!mounted)return;
    final confirmed=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:const Text('Replace current data?'),content:Text('Backup contains ${data['products']!.length} products, ${data['clients']!.length} customers and ${data['sales']!.length} invoices. Current records will be replaced, not merged. A safety backup must be saved first.'),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Continue'))]));
    if(confirmed!=true||!mounted)return;
    if(!await exportBackup())return;
    await widget.db.transaction((tx) async {
      for(final table in columns.keys.toList().reversed){await tx.delete(table);}
      for(final table in columns.keys){if(table=='stock_movements'){if(data[table]!.isNotEmpty){await tx.delete(table);for(final row in data[table]!){await tx.insert(table,row);}}}else{for(final row in data[table]!){await tx.insert(table,row);}}}
    });
    await widget.onRestored();
    if(mounted)setState(()=>status='Restore completed successfully.');
  }
  @override Widget build(BuildContext context)=>PopScope<Object?>(canPop:!busy,child:Scaffold(appBar:AppBar(title:const Text('Backup & Restore')),body:ListView(padding:const EdgeInsets.all(16),children:[
    const Text('Protect your business data',style:TextStyle(fontSize:22,fontWeight:FontWeight.bold)),
    const SizedBox(height:12),
    const Text('Backups contain private business and customer data. Save outside app storage and keep them secure. Export before uninstalling.'),
    const SizedBox(height:20),
    FilledButton.icon(onPressed:busy?null:()=>run(() async {await exportBackup();}),icon:const Icon(Icons.backup),label:const Text('Create & Save Backup')),
    OutlinedButton.icon(onPressed:busy?null:()=>run(restore),icon:const Icon(Icons.restore),label:const Text('Restore Backup')),
    if(busy)const LinearProgressIndicator(),
    if(status.isNotEmpty)Padding(padding:const EdgeInsets.only(top:16),child:Text(status)),
    const SizedBox(height:16),const Text('Backup format: MR Vision Tech JSON. Includes products, customers, invoices, invoice lines and settings. Restore replaces existing records.')
  ])));
}

class PaymentDialog extends StatefulWidget {
 const PaymentDialog({super.key,required this.total});
 final double total;
 @override State<PaymentDialog> createState()=>_PaymentDialogState();
}
class _PaymentDialogState extends State<PaymentDialog>{
 late final TextEditingController paid;
 String mode='Cash';
 String? error;
 @override void initState(){super.initState();paid=TextEditingController(text:widget.total.toStringAsFixed(2));}
 @override void dispose(){paid.dispose();super.dispose();}
 @override Widget build(BuildContext context){
 final amount=double.tryParse(paid.text);
 final valid=amount!=null&&amount.isFinite&&amount>=0&&amount<=double.parse(widget.total.toStringAsFixed(2));
 return AlertDialog(title:const Text('Payment details'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
 Text('Total: INR ${widget.total.toStringAsFixed(2)}'),
 DropdownButtonFormField<String>(value:mode,items:['Cash','UPI','Card','Bank Transfer','Credit'].map((m)=>DropdownMenuItem(value:m,child:Text(m))).toList(),onChanged:(v){if(v!=null)setState((){mode=v;if(v=='Credit')paid.text='0';});}),
 TextField(controller:paid,enabled:mode!='Credit',keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:InputDecoration(labelText:'Paid amount',errorText:error),onChanged:(_)=>setState(()=>error=null)),
 Text(valid?'Due: INR ${max(0.0,widget.total-amount!).toStringAsFixed(2)}':'Enter a valid amount'),
 const Text('Payment is recorded manually; not verified by bank.')
 ])),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancel')),FilledButton(onPressed:(){if(!valid){setState(()=>error='Invalid paid amount');return;}Navigator.pop(context,{'paid':amount,'mode':mode});},child:const Text('Save invoice'))]);
 }
}

class InvoiceEditor extends StatefulWidget {
 final Map<String,Object?> sale;
 final List<Map<String,Object?>> lines,products,logs;
 final double received;
 const InvoiceEditor({super.key,required this.sale,required this.lines,required this.products,required this.received,required this.logs});
 @override State<InvoiceEditor> createState()=>_InvoiceEditorState();
}
class _InvoiceEditorState extends State<InvoiceEditor> {
 late final TextEditingController customer,paid;
 late DateTime date;
 late String mode;
 late List<Map<String,Object?>> previous,lines;
 String error='';
 @override void initState(){super.initState();customer=TextEditingController(text:widget.sale['customer'].toString());paid=TextEditingController(text:widget.sale['paid']?.toString()??'');date=DateTime.parse(widget.sale['date'] as String);mode=widget.sale['payment_mode']?.toString()??'Cash';previous=widget.lines.map((r)=>Map<String,Object?>.from(r)).toList();lines=previous.map((r)=>Map<String,Object?>.from(r)).toList();}
 @override void dispose(){customer.dispose();paid.dispose();super.dispose();}
 double get total=>lines.fold<double>(0,(a,r)=>a+(r['qty'] as int)*(r['price'] as num)*(1+(r['gst'] as num)/100));
 Future<void> add() async {final product=await showDialog<Map<String,Object?>>(context:context,builder:(ctx)=>SimpleDialog(title:const Text('Add product'),children:widget.products.map((r)=>SimpleDialogOption(onPressed:()=>Navigator.pop(ctx,r),child:Text('${r['code']} • ${r['name']} (stock ${r['qty']})'))).toList()));if(product==null||!mounted)return;setState(()=>lines.add({'product_id':product['id'],'name':product['name'],'qty':1,'price':product['price'],'gst':product['gst'],'cost':product['cost'],'serials':'','warranty_snapshot':product['warranty']?.toString()??''}));}
 Future<void> save() async {
 try {
 if(customer.text.trim().isEmpty||lines.isEmpty)throw Exception('Customer and items required');
 final amount=paid.text.trim().isEmpty?null:double.tryParse(paid.text.trim());
 if(paid.text.trim().isNotEmpty&&(amount==null||!amount.isFinite||amount<0))throw Exception('Invalid paid amount');
 if(amount==null&&widget.received>0)throw Exception('Initial payment required');
 if(amount!=null&&(amount+widget.received>total+0.000001||(mode=='Credit'&&amount>0)))throw Exception('Invalid payment or total below collected amount');
 for(final old in previous.where((r)=>r['product_id']==null)){final same=lines.where((r)=>r['id']==old['id']).toList();if(same.length!=1||same.single['qty']!=old['qty']||same.single['product_id']!=null)throw Exception('Link legacy item to its original product before changing stock');}
 final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:const Text('Save invoice correction?'),content:Text('Invoice number stays unchanged. Existing collections remain. New total: ${money(total)}. For issued GST invoices use legally appropriate correction documents.'),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Save'))]));
 if(ok==true&&mounted)Navigator.pop(context,{'sale':{'customer':customer.text.trim(),'date':date.toIso8601String(),'total':total,'paid':amount,'payment_mode':amount==null?null:mode},'lines':lines,'previous':previous});
 }catch(e){setState(()=>error=e.toString());}
 }
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text('Edit ${widget.sale['number']}')),body:ListView(padding:const EdgeInsets.all(16),children:[TextField(controller:customer,decoration:const InputDecoration(labelText:'Customer name')),ListTile(title:Text(DateFormat('dd MMM yyyy').format(date)),trailing:const Icon(Icons.calendar_month),onTap:() async {final d=await showDatePicker(context:context,initialDate:date,firstDate:DateTime(1900),lastDate:DateTime(2100));if(d!=null&&mounted)setState(()=>date=DateTime(d.year,d.month,d.day,date.hour,date.minute,date.second));}),const Text('For legacy items, confirm the original product before changing quantity or removing it.'),...previous.where((r)=>r['product_id']==null).map((r)=>ListTile(title:Text('Link ${r['name']}'),subtitle:const Text('Select original stock item only'),onTap:() async {final id=await showDialog<int>(context:context,builder:(ctx)=>SimpleDialog(title:Text('Original product for ${r['name']}'),children:widget.products.map((p)=>SimpleDialogOption(onPressed:()=>Navigator.pop(ctx,p['id'] as int),child:Text('${p['code']} • ${p['name']}'))).toList()));if(id!=null&&mounted)setState((){r['product_id']=id;for(final l in lines.where((l)=>l['id']==r['id'])){l['product_id']=id;}});})),...List.generate(lines.length,(i){final r=lines[i];return Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(children:[ListTile(title:Text('${r['name']}'),trailing:IconButton(onPressed:r['product_id']==null?null:()=>setState(()=>lines.removeAt(i)),icon:const Icon(Icons.delete_outline))),TextFormField(key:ValueKey('serial-${identityHashCode(r)}'),initialValue:r['serials']?.toString()??'',maxLines:3,decoration:const InputDecoration(labelText:'Serial numbers (one per line)'),onChanged:(v)=>r['serials']=v),TextFormField(key:ValueKey('warranty-${identityHashCode(r)}'),initialValue:r['warranty_snapshot']?.toString()??'',decoration:const InputDecoration(labelText:'Warranty'),onChanged:(v)=>r['warranty_snapshot']=v),...['qty','price','gst'].map((k)=>TextFormField(key:ValueKey('${identityHashCode(r)}-$k'),initialValue:r[k].toString(),enabled:k!='qty'||r['product_id']!=null,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:InputDecoration(labelText:k),onChanged:(v){final n=k=='qty'?int.tryParse(v):double.tryParse(v);setState(()=>r[k]=n!=null&&n.isFinite&&n>=0&&(k!='qty'||n>0)&&(k!='gst'||n<=100)?n:null);}))])));}),OutlinedButton(onPressed:add,child:const Text('Add product')),TextField(controller:paid,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Initial paid amount (blank = unknown)')),DropdownButtonFormField<String>(value:mode,items:['Cash','UPI','Card','Bank Transfer','Credit'].map((m)=>DropdownMenuItem(value:m,child:Text(m))).toList(),onChanged:(v){if(v!=null)setState(()=>mode=v);}),Text('Later collections: ${money(widget.received)}'),Text('Total: ${lines.any((r)=>r['qty']==null||r['price']==null||r['gst']==null)?'Invalid item':money(total)}'),if(error.isNotEmpty)Text(error,style:TextStyle(color:Theme.of(context).colorScheme.error)),FilledButton(onPressed:lines.any((r)=>r['qty']==null||r['price']==null||r['gst']==null)?null:save,child:const Text('Save changes')),const Divider(),const Text('Edit history'),...widget.logs.map((r)=>ExpansionTile(title:Text(r['date'].toString()),children:[SelectableText(r['snapshot'].toString())]))]));
}

class BarcodeScanPage extends StatefulWidget {
 const BarcodeScanPage({super.key});
 @override State<BarcodeScanPage> createState()=>_BarcodeScanPageState();
}
class _BarcodeScanPageState extends State<BarcodeScanPage> {
 bool returned=false;
 final controller=MobileScannerController();
 @override void dispose(){controller.dispose();super.dispose();}
 @override Widget build(BuildContext context)=>Scaffold(
 appBar:AppBar(title:const Text('Scan barcode'),actions:[IconButton(onPressed:()=>controller.toggleTorch(),icon:const Icon(Icons.flashlight_on))]),
 body:Column(children:[Expanded(child:MobileScanner(controller:controller,onDetect:(capture){if(returned||!mounted)return;for(final barcode in capture.barcodes){final value=barcode.rawValue?.trim();if(value!=null&&value.isNotEmpty){returned=true;Navigator.pop(context,value);break;}}})),const Padding(padding:EdgeInsets.all(16),child:Text('Point camera at barcode. Allow camera permission when prompted. If unavailable, go back and enter the code manually.'))]));
}

List<String> serialList(Object? value)=> (value??'').toString().split('\n').map((v)=>v.trim()).where((v)=>v.isNotEmpty).toList();
void checkSerialRows(List<Map<String,Object?>> rows){
 final seen=<String>{};
 for(final r in rows){final serials=serialList(r['serials']);if(serials.isNotEmpty&&serials.length!=r['qty'])throw Exception('Serial count must equal quantity for ${r['name']}');for(final serial in serials){if(!seen.add(serial.toUpperCase()))throw Exception('Duplicate sold serial: $serial');}}
}
Future<void> validateSerials(DatabaseExecutor tx) async => checkSerialRows(await tx.query('lines'));
class SerialEntryDialog extends StatefulWidget {
 final String name;final int qty;
 const SerialEntryDialog({super.key,required this.name,required this.qty});
 @override State<SerialEntryDialog> createState()=>_SerialEntryDialogState();
}
class _SerialEntryDialogState extends State<SerialEntryDialog>{
 final controller=TextEditingController();String error='';
 @override void dispose(){controller.dispose();super.dispose();}
 @override Widget build(BuildContext context)=>AlertDialog(title:Text(widget.name),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[Text('Enter ${widget.qty} serial numbers, one per line, or skip for non-serialized items.'),TextField(controller:controller,minLines:2,maxLines:5,keyboardType:TextInputType.multiline,textInputAction:TextInputAction.newline,decoration:InputDecoration(labelText:'Serial numbers',errorText:error.isEmpty?null:error)),])),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancel sale')),TextButton(onPressed:()=>Navigator.pop(context,''),child:const Text('Skip')),FilledButton(onPressed:(){final values=serialList(controller.text);if(values.length!=widget.qty||values.map((v)=>v.toUpperCase()).toSet().length!=values.length){setState(()=>error='Enter unique serials matching quantity');return;}Navigator.pop(context,values.join('\n'));},child:const Text('Continue'))]);
}
class SerialLookup extends StatefulWidget{
 final Database db;const SerialLookup({super.key,required this.db});
 @override State<SerialLookup> createState()=>_SerialLookupState();
}
class _SerialLookupState extends State<SerialLookup>{
 String search='';late final Future<List<Map<String,Object?>>> rows=widget.db.rawQuery("SELECT l.*, s.number, s.date, s.customer FROM lines l JOIN sales s ON s.id=l.sale WHERE COALESCE(l.serials,'')!='' OR COALESCE(l.warranty_snapshot,'')!='' ORDER BY s.id DESC");
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Serial & Warranty Lookup')),body:Column(children:[Padding(padding:const EdgeInsets.all(12),child:TextField(decoration:const InputDecoration(labelText:'Search serial, product, customer or invoice'),onChanged:(v)=>setState(()=>search=v.toLowerCase().trim()))),Expanded(child:FutureBuilder<List<Map<String,Object?>>>(future:rows,builder:(context,snapshot){if(snapshot.hasError)return Center(child:Text('${snapshot.error}'));if(!snapshot.hasData)return const Center(child:CircularProgressIndicator());final filtered=snapshot.data!.where((r)=>r.values.join(' ').toLowerCase().contains(search)).toList();if(filtered.isEmpty)return const Center(child:Text('No matching records'));return ListView.builder(itemCount:filtered.length,itemBuilder:(context,i){final r=filtered[i];return Card(child:ListTile(title:Text('${r['name']} • ${r['number']}'),subtitle:Text("Customer: ${r['customer']}\nSale date: ${r['date']}\nSerial: ${r['serials']??''}\nWarranty: ${r['warranty_snapshot']??''}"),isThreeLine:true));});}))]));
}

Widget productPhoto(String data,double size){
 if(data.isNotEmpty){try{return ClipRRect(borderRadius:BorderRadius.circular(8),child:Image.memory(base64Decode(data),width:size,height:size,fit:BoxFit.cover,cacheWidth:320,errorBuilder:(_,__,___)=>Icon(Icons.broken_image,size:size/2)));}catch(_){}}
 return SizedBox(width:size,height:size,child:const Icon(Icons.inventory_2_outlined));
}
class CatalogPage extends StatefulWidget {
 final Database db; const CatalogPage({super.key,required this.db});
 @override State<CatalogPage> createState()=>_CatalogPageState();
}
class _CatalogPageState extends State<CatalogPage>{
 String field='category'; bool busy=false;
 Future<List<Map<String,Object?>>> load()=>widget.db.rawQuery('SELECT $field AS name, COUNT(*) AS count FROM products GROUP BY $field ORDER BY $field');
 Future<void> rename(String old) async {
 String value=old;
 final next=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(title:Text('Rename / merge $field'),content:TextFormField(initialValue:old,onChanged:(v)=>value=v,decoration:const InputDecoration(labelText:'New name')),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,value.trim()),child:const Text('Apply to all matching products'))]));
 if(next==null||next.isEmpty||next==old||!mounted)return;
 setState(()=>busy=true);
 try{await widget.db.update('products',{field:next},where:'COALESCE($field, ?) = ?',whereArgs:['',old]);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}finally{if(mounted)setState(()=>busy=false);}
 }
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Category & Brand Management')),body:Column(children:[SegmentedButton<String>(segments:const [ButtonSegment(value:'category',label:Text('Categories')),ButtonSegment(value:'brand',label:Text('Brands'))],selected:{field},onSelectionChanged:busy?null:(v)=>setState(()=>field=v.single)),const Padding(padding:EdgeInsets.all(12),child:Text('Create names in Add / Edit Product. Rename or merge existing names here. Item codes remain unchanged.')),Expanded(child:FutureBuilder<List<Map<String,Object?>>>(future:load(),builder:(context,s){if(s.hasError)return Center(child:Text('${s.error}'));if(!s.hasData)return const Center(child:CircularProgressIndicator());return ListView(children:s.data!.map((r)=>ListTile(title:Text((r['name']??'').toString().isEmpty?'Unassigned':r['name'].toString()),subtitle:Text('${r['count']} products'),trailing:IconButton(icon:const Icon(Icons.edit),onPressed:busy?null:()=>rename((r['name']??'').toString())))).toList());}))]));
}


class StockManagement extends StatefulWidget {
  final Database db;
  const StockManagement({super.key,required this.db});
  @override State<StockManagement> createState()=>_StockManagementState();
}
class _StockManagementState extends State<StockManagement>{
  String search=''; bool busy=false;
  Future<void> adjust(Map<String,Object?> product) async {
    final result=await showDialog<List<String>>(context:context,builder:(_)=>const StockAdjustmentDialog());
    if(result==null||!mounted)return;
    final delta=int.tryParse(result[0]);
    if(delta==null||delta==0||result[1].trim().isEmpty)return;
    setState(()=>busy=true);
    try{await widget.db.transaction((tx) async {
      final n=await tx.rawUpdate('UPDATE products SET qty=qty+? WHERE id=? AND qty+?>=0',[delta,product['id'],delta]);
      if(n!=1)throw Exception('Insufficient stock or missing product');
      await tx.rawUpdate('UPDATE stock_movements SET reason=? WHERE id=(SELECT MAX(id) FROM stock_movements WHERE product_id=?)',['Adjustment: ${result[1].trim()}',product['id']]);
    });}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}finally{if(mounted)setState(()=>busy=false);}
  }
  Future<List<Map<String,Object?>>> audit() => widget.db.rawQuery('SELECT p.id,p.code,p.name,p.qty,COALESCE((SELECT SUM(m.after_qty-m.before_qty) FROM stock_movements m WHERE m.product_id=p.id),0) AS recorded FROM products p ORDER BY p.name');
  Future<void> report() async {
    final rows=await widget.db.query('stock_movements',orderBy:'id DESC');
    final doc=pw.Document();
    doc.addPage(pw.MultiPage(pageFormat:PdfPageFormat.a4,build:(_)=>[pw.Text('Stock Movement Report',style:pw.TextStyle(fontSize:18)),pw.TableHelper.fromTextArray(headers:['Date','Code','Before','After','Reason'],data:rows.map((r)=>[r['date'],r['code'],r['before_qty'],r['after_qty'],r['reason']]).toList(),cellStyle:const pw.TextStyle(fontSize:8))]));
    final bytes=await doc.save();if(!mounted)return;
    await Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>Scaffold(appBar:AppBar(title:const Text('Stock report')),body:PdfPreview(build:(_) async=>bytes))));
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Stock Management'),actions:[IconButton(onPressed:busy?null:() async {try{await report();}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}},icon:const Icon(Icons.picture_as_pdf))]),body:Column(children:[Padding(padding:const EdgeInsets.all(12),child:TextField(decoration:const InputDecoration(labelText:'Search product or code'),onChanged:(v)=>setState(()=>search=v.toLowerCase()))),Expanded(child:FutureBuilder<List<Map<String,Object?>>>(future:audit(),builder:(ctx,s){if(s.hasError)return Center(child:Text('${s.error}'));if(!s.hasData)return const Center(child:CircularProgressIndicator());final rows=s.data!.where((r)=>'${r['name']} ${r['code']}'.toLowerCase().contains(search)).toList();return ListView(children:rows.map((r)=>ListTile(title:Text('${r['name']}'),subtitle:Text('${r['code']} • Stock: ${r['qty']} • ${r['qty']==r['recorded']?'Audit OK':'Audit mismatch: ${r['recorded']}'}'),onTap:()=>Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>StockHistory(db:widget.db,product:r))),trailing:IconButton(onPressed:busy?null:()=>adjust(r),icon:const Icon(Icons.tune),tooltip:'Adjust stock'))).toList());}))]));
}
class StockHistory extends StatelessWidget{
  final Database db;final Map<String,Object?> product;
  const StockHistory({super.key,required this.db,required this.product});
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text('${product['name']}')),body:FutureBuilder<List<Map<String,Object?>>>(future:db.query('stock_movements',where:'product_id=?',whereArgs:[product['id']],orderBy:'id DESC'),builder:(ctx,s){if(s.hasError)return Center(child:Text('${s.error}'));if(!s.hasData)return const Center(child:CircularProgressIndicator());return ListView(children:s.data!.map((r){final delta=(r['after_qty'] as int)-(r['before_qty'] as int);return ListTile(title:Text('${delta>=0?'+':''}$delta • ${r['reason']}'),subtitle:Text('${r['date']}\n${r['before_qty']} → ${r['after_qty']}'));}).toList());}));
}
class StockAdjustmentDialog extends StatefulWidget{
  const StockAdjustmentDialog({super.key});
  @override State<StockAdjustmentDialog> createState()=>_StockAdjustmentDialogState();
}
class _StockAdjustmentDialogState extends State<StockAdjustmentDialog>{
  final qty=TextEditingController(),reason=TextEditingController();bool incoming=true;String? error;
  @override void dispose(){qty.dispose();reason.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>AlertDialog(title:const Text('Stock Adjustment'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[SwitchListTile(title:Text(incoming?'Stock IN':'Stock OUT'),value:incoming,onChanged:(v)=>setState(()=>incoming=v)),TextField(controller:qty,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Quantity')),TextField(controller:reason,decoration:const InputDecoration(labelText:'Reason (required)')),if(error!=null)Text(error!)])),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancel')),FilledButton(onPressed:(){final n=int.tryParse(qty.text);if(n==null||n<=0||reason.text.trim().isEmpty){setState(()=>error='Enter positive quantity and reason');return;}Navigator.pop(context,[(incoming?n:-n).toString(),reason.text]);},child:const Text('Save'))]);
}

class PurchasePage extends StatefulWidget {
  final Database db;
  const PurchasePage({super.key,required this.db});
  @override State<PurchasePage> createState()=>_PurchasePageState();
}
class _PurchasePageState extends State<PurchasePage>{
  bool busy=false;
  Future<void> run(Future<void> Function() fn) async {
    if(busy)return;setState(()=>busy=true);
    try{await fn();}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> supplier([Map<String,Object?>? old]) async {
    final result=await showDialog<List<String>>(context:context,builder:(_)=>SupplierForm(old:old));
    if(result==null)return;
    final row={'name':result[0],'phone':result[1],'address':result[2]};
    if(old==null){await widget.db.insert('suppliers',row);}else{await widget.db.update('suppliers',row,where:'id=?',whereArgs:[old['id']]);}
  }
  Future<void> purchase() async {
    final suppliers=await widget.db.query('suppliers',orderBy:'name');
    final products=await widget.db.query('products',orderBy:'name');
    if(suppliers.isEmpty||products.isEmpty)throw Exception('Add a supplier and products first');
    if(!mounted)return;
    await Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>PurchaseForm(db:widget.db,suppliers:suppliers,products:products)));
  }
  Future<List<Map<String,Object?>>> history()=>widget.db.rawQuery('SELECT p.*,s.name AS supplier FROM purchases p JOIN suppliers s ON s.id=p.supplier_id ORDER BY p.id DESC');
  @override Widget build(BuildContext context)=>DefaultTabController(length:2,child:Scaffold(appBar:AppBar(title:const Text('Purchase & Suppliers'),bottom:const TabBar(tabs:[Tab(text:'Purchases'),Tab(text:'Suppliers')])),body:TabBarView(children:[Column(children:[Padding(padding:const EdgeInsets.all(12),child:FilledButton.icon(onPressed:busy?null:()=>run(purchase),icon:const Icon(Icons.add),label:const Text('New purchase'))),Expanded(child:FutureBuilder<List<Map<String,Object?>>>(future:history(),builder:(ctx,s){if(s.hasError)return Center(child:Text('${s.error}'));if(!s.hasData)return const Center(child:CircularProgressIndicator());final rows=s.data!;return ListView(children:[ListTile(title:const Text('Total supplier due'),trailing:Text(money(rows.fold<num>(0,(a,r)=>a+(r['total'] as num)-(r['paid'] as num))))),...rows.map((r)=>ListTile(title:Text('${r['number']} • ${r['supplier']}'),subtitle:Text('${r['date']}\nDue: ${money((r['total'] as num)-(r['paid'] as num))}'),trailing:Text(money(r['total'] as num)),onTap:()=>run(() async {await Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>PurchaseDetails(db:widget.db,row:r)));})))]);}))]),Column(children:[Padding(padding:const EdgeInsets.all(12),child:FilledButton.icon(onPressed:busy?null:()=>run(()=>supplier()),icon:const Icon(Icons.person_add),label:const Text('Add supplier'))),Expanded(child:FutureBuilder<List<Map<String,Object?>>>(future:widget.db.rawQuery('SELECT s.*,COALESCE((SELECT SUM(total-paid) FROM purchases p WHERE p.supplier_id=s.id),0) AS due FROM suppliers s ORDER BY name'),builder:(ctx,s){if(s.hasError)return Center(child:Text('${s.error}'));if(!s.hasData)return const Center(child:CircularProgressIndicator());return ListView(children:s.data!.map((r)=>ListTile(title:Text('${r['name']}'),subtitle:Text('${r['phone']}\nDue: ${money(r['due'] as num)}'),onTap:()=>run(() async {await Navigator.push(context,MaterialPageRoute<void>(builder:(_)=>SupplierLedgerPage(db:widget.db,supplier:r)));}),trailing:IconButton(icon:const Icon(Icons.edit),onPressed:busy?null:()=>run(()=>supplier(r))))).toList());}))])])));
}
class SupplierForm extends StatefulWidget{
 final Map<String,Object?>? old;const SupplierForm({super.key,this.old});
 @override State<SupplierForm> createState()=>_SupplierFormState();
}
class _SupplierFormState extends State<SupplierForm>{
 late final name=TextEditingController(text:widget.old?['name']?.toString()??'');
 late final phone=TextEditingController(text:widget.old?['phone']?.toString()??'');
 late final address=TextEditingController(text:widget.old?['address']?.toString()??'');
 @override void dispose(){name.dispose();phone.dispose();address.dispose();super.dispose();}
 @override Widget build(BuildContext context)=>AlertDialog(title:const Text('Supplier'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:name,decoration:const InputDecoration(labelText:'Name')),TextField(controller:phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'Phone')),TextField(controller:address,decoration:const InputDecoration(labelText:'Address'))])),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancel')),FilledButton(onPressed:(){if(name.text.trim().isEmpty)return;Navigator.pop(context,[name.text.trim(),phone.text.trim(),address.text.trim()]);},child:const Text('Save'))]);
}
class PurchaseForm extends StatefulWidget{
 final Database db;final List<Map<String,Object?>> suppliers,products;
 const PurchaseForm({super.key,required this.db,required this.suppliers,required this.products});
 @override State<PurchaseForm> createState()=>_PurchaseFormState();
}
class _PurchaseFormState extends State<PurchaseForm>{
 int? supplier,product;bool busy=false;final items=<Map<String,Object?>>[];
 final number=TextEditingController(),qty=TextEditingController(text:'1'),cost=TextEditingController(),paid=TextEditingController(text:'0');
 double get total=>items.fold<double>(0,(a,r)=>a+(r['qty'] as int)*(r['cost'] as double));
 @override void dispose(){number.dispose();qty.dispose();cost.dispose();paid.dispose();super.dispose();}
 void msg(String s)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));
 void add(){final q=int.tryParse(qty.text),c=double.tryParse(cost.text);if(product==null||q==null||q<=0||q>100000000||c==null||!c.isFinite||c<0||!(q*c).isFinite){msg('Enter valid product, quantity and cost');return;}if(items.any((r)=>r['product_id']==product)){msg('Remove existing line before adding this product again');return;}final r=widget.products.firstWhere((r)=>r['id']==product);setState(()=>items.add({'product_id':product,'name':r['name'],'qty':q,'cost':c}));}
 Future<void> save() async {if(busy)return;final payment=double.tryParse(paid.text);if(supplier==null||number.text.trim().isEmpty||items.isEmpty||!total.isFinite||payment==null||!payment.isFinite||payment<0||payment>total){msg('Check supplier, invoice number, items and paid amount');return;}setState(()=>busy=true);try{await widget.db.transaction((tx) async {final id=await tx.insert('purchases',{'supplier_id':supplier,'number':number.text.trim(),'date':DateTime.now().toIso8601String(),'total':total,'paid':payment});for(final r in items){final n=await tx.rawUpdate('UPDATE products SET qty=qty+?,cost=? WHERE id=?',[r['qty'],r['cost'],r['product_id']]);if(n!=1)throw Exception('Product no longer exists');await tx.rawUpdate('UPDATE stock_movements SET reason=? WHERE id=(SELECT MAX(id) FROM stock_movements WHERE product_id=?)',['Purchase ${number.text.trim()}',r['product_id']]);await tx.insert('purchase_lines',{'purchase_id':id,...r});}});if(mounted)Navigator.pop(context);}catch(e){if(mounted)msg('Purchase failed: $e');}finally{if(mounted)setState(()=>busy=false);}}
 @override Widget build(BuildContext context)=>PopScope(canPop:!busy,child:Scaffold(appBar:AppBar(title:const Text('New Purchase')),body:AbsorbPointer(absorbing:busy,child:ListView(padding:const EdgeInsets.all(16),children:[DropdownButtonFormField<int>(isExpanded:true,value:supplier,decoration:const InputDecoration(labelText:'Supplier'),items:widget.suppliers.map((r)=>DropdownMenuItem<int>(value:r['id'] as int,child:Text('${r['name']}',overflow:TextOverflow.ellipsis))).toList(),onChanged:(v)=>setState(()=>supplier=v)),TextField(controller:number,decoration:const InputDecoration(labelText:'Supplier invoice number')),const Divider(),DropdownButtonFormField<int>(isExpanded:true,value:product,decoration:const InputDecoration(labelText:'Product'),items:widget.products.map((r)=>DropdownMenuItem<int>(value:r['id'] as int,child:Text('${r['name']}',overflow:TextOverflow.ellipsis))).toList(),onChanged:(v)=>setState((){product=v;cost.text=widget.products.firstWhere((r)=>r['id']==v)['cost']?.toString()??'0';})),TextField(controller:qty,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Quantity')),TextField(controller:cost,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Unit purchase cost (including tax)')),OutlinedButton(onPressed:add,child:const Text('Add item')),...items.asMap().entries.map((e)=>ListTile(title:Text('${e.value['name']}'),subtitle:Text('${e.value['qty']} × ${money(e.value['cost'] as num)}'),trailing:IconButton(icon:const Icon(Icons.delete_outline),onPressed:()=>setState(()=>items.removeAt(e.key))))),Text('Total: ${money(total)}'),TextField(controller:paid,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:const InputDecoration(labelText:'Paid amount')),FilledButton(onPressed:busy?null:save,child:const Text('Save purchase'))]))));
}
Future<void> supplierPdf(String title,List<String> rows) async {
 final doc=pw.Document();
 doc.addPage(pw.MultiPage(pageFormat:PdfPageFormat.a4,build:(_)=>[pw.Text(title,style:pw.TextStyle(fontSize:18)),pw.SizedBox(height:12),...rows.map((r)=>pw.Padding(padding:const pw.EdgeInsets.only(bottom:6),child:pw.Text(r.replaceAll('₹','INR '))))]));
 await Printing.sharePdf(bytes:await doc.save(),filename:'supplier_report.pdf');
}
class PurchaseDetails extends StatefulWidget{
 final Database db;final Map<String,Object?> row;const PurchaseDetails({super.key,required this.db,required this.row});
 @override State<PurchaseDetails> createState()=>_PurchaseDetailsState();
}
class _PurchaseDetailsState extends State<PurchaseDetails>{
 bool busy=false;
 int get id=>widget.row['id'] as int;
 Future<void> run(Future<void> Function() fn) async {if(busy)return;setState(()=>busy=true);try{await fn();}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}finally{if(mounted)setState(()=>busy=false);}}
 Future<Map<String,Object?>> current(DatabaseExecutor tx) async =>(await tx.query('purchases',where:'id=?',whereArgs:[id])).single;
 Future<void> event(DatabaseExecutor tx,String mode,num amount,Object snapshot) async {await tx.insert('supplier_events',{'purchase_id':id,'date':DateTime.now().toIso8601String(),'amount':amount,'mode':mode,'snapshot':jsonEncode(snapshot)});}
 Future<String?> ask(String title,String label) async =>showDialog<String>(context:context,builder:(_)=>SupplierValueDialog(title:title,label:label));
 Future<void> payment() async {final input=await ask('Pay supplier','Amount');if(input==null)return;final a=double.tryParse(input);if(a==null||!a.isFinite||a<=0)throw Exception('Invalid amount');await widget.db.transaction((tx) async {final r=await current(tx);final paid=r['paid'] as num;final total=r['total'] as num;if(a>total-paid)throw Exception('Amount exceeds due');await tx.update('purchases',{'paid':paid+a},where:'id=?',whereArgs:[id]);await event(tx,'Payment',a,{'number':r['number']});});}
 Future<void> change(Map<String,Object?> line,bool returning) async {
 final input=await ask(returning?'Purchase return':'Edit purchase quantity',returning?'Quantity to return':'New quantity');if(input==null)return;final q=int.tryParse(input);if(q==null||q<=0||q>100000000)throw Exception('Invalid quantity');
 await widget.db.transaction((tx) async {final r=await current(tx);final l=(await tx.query('purchase_lines',where:'id=? AND purchase_id=?',whereArgs:[line['id'],id])).single;final old=l['qty'] as int;final next=returning?old-q:q;if(next<0)throw Exception('Return exceeds purchased quantity');final delta=next-old;if(delta==0)return;final cost=l['cost'] as num;final total=(r['total'] as num)+delta*cost;if(total<(r['paid'] as num))throw Exception('Change would create supplier credit; refund handling is not supported yet');final product=l['product_id'];final n=await tx.rawUpdate('UPDATE products SET qty=qty+? WHERE id=? AND qty+?>=0',[delta,product,delta]);if(n!=1)throw Exception('Insufficient stock or missing product');await tx.rawUpdate('UPDATE stock_movements SET reason=? WHERE id=(SELECT MAX(id) FROM stock_movements WHERE product_id=?)',[returning?'Purchase return ${r['number']}':'Purchase edit ${r['number']}',product]);if(next==0){final count=Sqflite.firstIntValue(await tx.rawQuery('SELECT COUNT(*) FROM purchase_lines WHERE purchase_id=?',[id]))??0;if(count<=1)throw Exception('Full invoice return is not supported yet');await tx.delete('purchase_lines',where:'id=?',whereArgs:[l['id']]);}else{await tx.update('purchase_lines',{'qty':next},where:'id=?',whereArgs:[l['id']]);}await tx.update('purchases',{'total':total},where:'id=?',whereArgs:[id]);await event(tx,returning?'Return':'Edit',(delta*cost).abs(),{'before':l,'after_qty':next});});}
 Future<List<Object>> load() async =>[await current(widget.db),await widget.db.query('purchase_lines',where:'purchase_id=?',whereArgs:[id]),await widget.db.query('supplier_events',where:'purchase_id=?',whereArgs:[id],orderBy:'id DESC')];
 @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text('${widget.row['number']}')),body:FutureBuilder<List<Object>>(future:load(),builder:(ctx,s){if(s.hasError)return Center(child:Text('${s.error}'));if(!s.hasData)return const Center(child:CircularProgressIndicator());final r=s.data![0] as Map<String,Object?>;final lines=s.data![1] as List<Map<String,Object?>>;final events=s.data![2] as List<Map<String,Object?>>;return ListView(children:[ListTile(title:Text('${widget.row['supplier']}'),subtitle:Text('${r['date']}')),for(final l in lines) ListTile(title:Text('${l['name']}'),subtitle:Text('${l['qty']} x ${money(l['cost'] as num)}'),trailing:Wrap(children:[IconButton(tooltip:'Edit quantity',onPressed:busy?null:()=>run(()=>change(l,false)),icon:const Icon(Icons.edit)),IconButton(tooltip:'Return item',onPressed:busy?null:()=>run(()=>change(l,true)),icon:const Icon(Icons.assignment_return))])),ListTile(title:const Text('Total'),trailing:Text(money(r['total'] as num))),ListTile(title:const Text('Paid'),trailing:Text(money(r['paid'] as num))),ListTile(title:const Text('Due'),trailing:Text(money((r['total'] as num)-(r['paid'] as num)))),FilledButton(onPressed:busy?null:()=>run(payment),child:const Text('Pay supplier')),const ListTile(title:Text('Payment and adjustment history')),for(final e in events) ListTile(title:Text('${e['mode']} - ${money(e['amount'] as num)}'),subtitle:Text('${e['date']}'),trailing:e['mode']=='Payment'?IconButton(icon:const Icon(Icons.picture_as_pdf),onPressed:busy?null:()=>run(()=>supplierPdf('Supplier payment receipt',['Receipt ${e['id']}','Supplier: ${widget.row['supplier']}','Purchase: ${r['number']}','Date: ${e['date']}','Amount: ${money(e['amount'] as num)}']))):null)]);}));
}
class SupplierValueDialog extends StatefulWidget {final String title,label;const SupplierValueDialog({super.key,required this.title,required this.label});@override State<SupplierValueDialog> createState()=>_SupplierValueDialogState();}
class _SupplierValueDialogState extends State<SupplierValueDialog>{final c=TextEditingController();@override void dispose(){c.dispose();super.dispose();}@override Widget build(BuildContext context)=>AlertDialog(title:Text(widget.title),content:TextField(controller:c,keyboardType:const TextInputType.numberWithOptions(decimal:true),decoration:InputDecoration(labelText:widget.label)),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(context,c.text.trim()),child:const Text('Confirm'))]);}
class SupplierLedgerPage extends StatelessWidget{final Database db;final Map<String,Object?> supplier;const SupplierLedgerPage({super.key,required this.db,required this.supplier});@override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text('${supplier['name']}')),body:FutureBuilder<List<Map<String,Object?>>>(future:db.query('purchases',where:'supplier_id=?',whereArgs:[supplier['id']],orderBy:'date DESC'),builder:(ctx,s){if(s.hasError)return Center(child:Text('${s.error}'));if(!s.hasData)return const Center(child:CircularProgressIndicator());final rows=s.data!;final due=rows.fold<num>(0,(a,r)=>a+(r['total'] as num)-(r['paid'] as num));return ListView(children:[ListTile(title:const Text('Outstanding'),trailing:Text(money(due))),OutlinedButton(onPressed:() async {try{await supplierPdf('Supplier statement - ${supplier['name']}',[for(final r in rows) '${r['date']} | ${r['number']} | Total ${money(r['total'] as num)} | Paid ${money(r['paid'] as num)}','Outstanding: ${money(due)}']);}catch(e){if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$e')));}},child:const Text('Share PDF statement')),for(final r in rows) ListTile(title:Text('${r['number']}'),subtitle:Text('${r['date']} | Paid ${money(r['paid'] as num)}'),trailing:Text(money((r['total'] as num)-(r['paid'] as num))))]);}));}
