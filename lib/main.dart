import 'dart:convert';
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await openDatabase(p.join(await getDatabasesPath(), 'mr_vision.db'), version: 2, onUpgrade: (d,old,v) async {if(old<2){await d.execute('ALTER TABLE products ADD COLUMN cost REAL');await d.execute('ALTER TABLE products ADD COLUMN category TEXT DEFAULT \'General\'');await d.execute('ALTER TABLE products ADD COLUMN barcode TEXT');await d.execute('ALTER TABLE lines ADD COLUMN cost REAL');}}, onCreate: (d,v) async {
    await d.execute('CREATE TABLE products(id INTEGER PRIMARY KEY, code TEXT UNIQUE, name TEXT, price REAL, qty INTEGER, gst REAL, cost REAL, category TEXT, barcode TEXT)');
    await d.execute('CREATE TABLE clients(id INTEGER PRIMARY KEY, name TEXT, phone TEXT, address TEXT)');
    await d.execute('CREATE TABLE sales(id INTEGER PRIMARY KEY, number TEXT UNIQUE, date TEXT, customer TEXT, total REAL)');
    await d.execute('CREATE TABLE lines(id INTEGER PRIMARY KEY, sale INTEGER, name TEXT, qty INTEGER, price REAL, gst REAL, cost REAL)');
  });
  await db.execute('CREATE TABLE IF NOT EXISTS preferences(k TEXT PRIMARY KEY, v TEXT)');
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

 int tab=0; String search=''; String category='All'; bool lowOnly=false; bool busy=false; int? client;
 List<Map<String,Object?>> products=[],clients=[],sales=[]; final Map<int,int> cart={};
 @override void initState(){super.initState(); refresh();}
 Future<void> refresh() async {final a=await widget.db.query('products',orderBy:'name');final b=await widget.db.query('clients',orderBy:'name');final c=await widget.db.query('sales',orderBy:'id DESC');if(mounted)setState((){products=a;clients=b;sales=c;});}
 final List<int> history=[];
 void go(int i){if(i==tab)return;setState((){if(i==0){history.clear();}else{history.add(tab);}tab=i;search='';});}
 void back(){if(tab==0){_confirmExit();return;}setState((){tab=history.isEmpty?0:history.removeLast();search='';});}
 void message(String s){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));}
 double total(Map<String,Object?> r,int q)=>(r['price'] as num).toDouble()*q*(1+(r['gst'] as num)/100);
 double get cartTotal=>products.fold(0.0,(s,r)=>s+total(r,cart[r['id']]??0));
 Future<void> edit(bool product,[Map<String,Object?>? record]) async {
 final v=await Navigator.of(context).push<List<String>>(MaterialPageRoute(builder:(_)=>_RecordDialog(product:product,record:record)));
 if(!mounted||v==null)return;
 try{if(product){final price=double.tryParse(v[2]);final qty=int.tryParse(v[3]);final gst=double.tryParse(v[4]);if(v[0].isEmpty||v[1].isEmpty||price==null||!price.isFinite||price<0||qty==null||qty<0||gst==null||!gst.isFinite||gst<0||gst>100)throw Exception('Enter valid product details');final cost=v[5].isEmpty?null:double.tryParse(v[5]);if(v[5].isNotEmpty&&(cost==null||!cost.isFinite||cost<0))throw Exception('Invalid purchase price');final data={'code':v[0],'name':v[1],'price':price,'qty':qty,'gst':gst,'cost':cost,'category':v[6],'barcode':v[7]};if(record==null){await widget.db.insert('products',data);}else{await widget.db.update('products',data,where:'id=?',whereArgs:[record['id']]);cart.clear();}}else{if(v[0].isEmpty)throw Exception('Name is required');final data={'name':v[0],'phone':v[1],'address':v[2]};if(record==null){await widget.db.insert('clients',data);}else{await widget.db.update('clients',data,where:'id=?',whereArgs:[record['id']]);}}await refresh();message('Saved successfully');}catch(e){message('Could not save: $e');}
 }
 Future<void> checkout() async {if(busy||!cart.values.any((q)=>q>0))return;setState(()=>busy=true);try{final number='MR-${DateFormat('ddMMyy').format(DateTime.now())}-${Random.secure().nextInt(0x10000).toRadixString(16).padLeft(4,'0').toUpperCase()}';await widget.db.transaction((tx) async {final id=await tx.insert('sales',{'number':number,'date':DateTime.now().toIso8601String(),'customer':clients.firstWhere((r)=>r['id']==client,orElse:()=>{'name':'Walk-in'})['name'],'total':cartTotal});for(final r in products){final q=cart[r['id']]??0;if(q==0)continue;final changed=await tx.rawUpdate('UPDATE products SET qty=qty-? WHERE id=? AND qty>=?',[q,r['id'],q]);if(changed!=1)throw Exception('Insufficient stock');await tx.insert('lines',{'sale':id,'name':r['name'],'qty':q,'price':r['price'],'gst':r['gst'],'cost':r['cost']});}});cart.clear();await refresh();if(mounted){go(3);message('Invoice saved');}}catch(e){message('Sale failed: $e');}finally{if(mounted)setState(()=>busy=false);}}
 Future<void> invoice(Map<String,Object?> r) async {
 try {
 final lines=await widget.db.query('lines',where:'sale=?',whereArgs:[r['id']]);
 final subtotal=lines.fold<double>(0,(a,l)=>a+(l['price'] as num)*(l['qty'] as num));
 final grand=(r['total'] as num).toDouble();
 final doc=pw.Document();
 final template=(int.tryParse(widget.settings['invoice_template']??'0')??0).clamp(0,5).toInt();
 final accent=[PdfColors.black,PdfColors.grey800,PdfColors.grey700,PdfColors.blue900,PdfColor.fromInt(0xff94742c),PdfColors.teal800][template];
 final classic=template==0||template==2;
 final ink=classic?PdfColors.black:PdfColors.white;
 final band=classic?PdfColors.grey200:accent;
 final logo=pw.MemoryImage((await rootBundle.load('assets/logo.png')).buffer.asUint8List());
 final cfg=widget.settings;
 final upi=cfg['upi']??'';
 final qr=Uri(scheme:'upi',host:'pay',queryParameters:{'pa':upi,'pn':cfg['business']??'MR Vision Tech','am':grand.toStringAsFixed(2),'cu':'INR','tn':'Invoice ${r['number']}'}).toString();
 String amount(num n)=>NumberFormat('#,##,##0.00','en_IN').format(n);
 final taxes=<double,double>{};
 for(final l in lines){final rate=(l['gst'] as num).toDouble();taxes[rate]=(taxes[rate]??0)+(l['price'] as num)*(l['qty'] as num)*rate/100;}
 final gst=taxes.keys.any((v)=>v>0)||(cfg['gstin']??'').trim().isNotEmpty;
 final business=cfg['business']??'MR Vision Tech';
 final date=DateFormat('dd MMM yyyy').format(DateTime.parse(r['date'] as String));
 final matches=await widget.db.query('clients',where:'name=?',whereArgs:[r['customer']]);
 final customer=matches.length==1?matches.first:<String,Object?>{};
 final terms=(cfg['terms']??'').replaceFirst(RegExp(r'^\s*terms\s*(?:&|and)\s*conditions\s*:?\s*',caseSensitive:false),'').trim();
 pw.Widget label(String t)=>pw.Text(t,style:pw.TextStyle(fontSize:10,color:accent,fontWeight:pw.FontWeight.bold));
 pw.Widget company({bool centered=false})=>pw.Column(crossAxisAlignment:centered?pw.CrossAxisAlignment.center:pw.CrossAxisAlignment.start,children:[pw.Text(business,style:pw.TextStyle(fontSize:25,color:accent,fontWeight:pw.FontWeight.bold)),pw.Text(cfg['address']??'',style:const pw.TextStyle(fontSize:11)),pw.Text(cfg['phone']??'',style:const pw.TextStyle(fontSize:11)),if((cfg['gstin']??'').isNotEmpty)pw.Text('GSTIN: ${cfg['gstin']}')]);
 pw.Widget meta()=>pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.end,children:[pw.Text('INVOICE',style:pw.TextStyle(fontSize:22,color:accent,fontWeight:pw.FontWeight.bold)),pw.Text('${r['number']}'),pw.Text(date)]);
 pw.Widget header(){
 if(template==4)return pw.Column(children:[pw.Image(logo,width:65,height:65),company(centered:true),pw.Divider(color:accent,thickness:2),pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[label('INVOICE'),pw.Text('${r['number']}  |  $date')])]);
 if(template==1)return pw.Column(children:[pw.Row(children:[pw.Image(logo,width:65,height:65),pw.SizedBox(width:12),pw.Expanded(child:company())]),pw.Container(color:band,padding:const pw.EdgeInsets.all(10),child:pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[pw.Text('INVOICE',style:pw.TextStyle(color:ink,fontWeight:pw.FontWeight.bold)),pw.Text('${r['number']}  |  $date',style:pw.TextStyle(color:ink))]))]);
 if(template==5)return pw.Column(children:[pw.Row(children:[pw.Expanded(child:company()),pw.Image(logo,width:68,height:68)]),pw.Divider(color:accent,thickness:3),pw.Align(alignment:pw.Alignment.centerLeft,child:pw.Text('INVOICE  /  ${r['number']}  /  $date',style:pw.TextStyle(color:accent,fontWeight:pw.FontWeight.bold)))]);
 return pw.Column(children:[pw.Row(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[pw.Image(logo,width:template==2?48:72,height:template==2?48:72),pw.SizedBox(width:12),pw.Expanded(child:company()),meta()]),pw.Divider(color:accent,thickness:template==3?4:1)]);
 }
 pw.Widget bill()=>pw.Container(width:double.infinity,padding:const pw.EdgeInsets.all(12),decoration:pw.BoxDecoration(border:pw.Border.all(color:PdfColors.grey400)),child:pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[label('BILL TO'),pw.SizedBox(height:5),pw.Text('${r['customer']}',style:pw.TextStyle(fontSize:15,fontWeight:pw.FontWeight.bold)),if((customer['phone']??'').toString().isNotEmpty)pw.Text('Mobile: ${customer['phone']}'),if((customer['address']??'').toString().isNotEmpty)pw.Text('${customer['address']}')]));
 pw.Widget summary(String title,String value)=>pw.Padding(padding:const pw.EdgeInsets.all(7),child:pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[pw.Text(title),pw.Text(value)]));
 pw.Widget total()=>pw.Container(decoration:pw.BoxDecoration(border:pw.Border.all(color:PdfColors.grey400)),child:pw.Column(children:[summary('Subtotal',amount(subtotal)),if(gst)summary('GST',amount(grand-subtotal)),pw.Container(color:band,padding:const pw.EdgeInsets.all(12),child:pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[pw.Text('TOTAL (INR)',style:pw.TextStyle(color:ink,fontWeight:pw.FontWeight.bold)),pw.Text(amount(grand),style:pw.TextStyle(color:ink,fontSize:18,fontWeight:pw.FontWeight.bold))]))]));
 pw.Widget payment()=>pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[if(upi.contains('@')&&grand>0&&cfg['qr']!='0')pw.Row(children:[pw.BarcodeWidget(barcode:pw.Barcode.qrCode(),data:qr,width:76,height:76),pw.SizedBox(width:8),pw.Expanded(child:pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[label('SCAN TO PAY'),pw.Text(upi),pw.Text('Verify outstanding amount before payment',style:const pw.TextStyle(fontSize:9))]))])]);
 pw.Widget taxSummary()=>pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[if(gst)...[label('GST SUMMARY'),...taxes.entries.map((e)=>pw.Text('${e.key.toStringAsFixed(2)}% : INR ${amount(e.value)}'))]]);
 doc.addPage(pw.MultiPage(pageFormat:PdfPageFormat.a4,margin:const pw.EdgeInsets.all(10*PdfPageFormat.mm),header:(_)=>header(),footer:(ctx)=>pw.Column(children:[pw.Divider(color:accent),pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[pw.Text('Thank you for your business.'),pw.Text('Page ${ctx.pageNumber} / ${ctx.pagesCount}')])]),build:(_)=>[
 pw.SizedBox(height:12),bill(),pw.SizedBox(height:16),
 pw.TableHelper.fromTextArray(headerDecoration:pw.BoxDecoration(color:band),headerStyle:pw.TextStyle(color:ink,fontSize:10,fontWeight:pw.FontWeight.bold),cellStyle:const pw.TextStyle(fontSize:10),cellPadding:pw.EdgeInsets.all(template==2?5:9),cellAlignments:{0:pw.Alignment.center,2:pw.Alignment.centerRight,3:pw.Alignment.centerRight,4:pw.Alignment.centerRight,5:pw.Alignment.centerRight,6:pw.Alignment.centerRight,7:pw.Alignment.centerRight},columnWidths:{0:const pw.FlexColumnWidth(.55),1:const pw.FlexColumnWidth(3),2:const pw.FlexColumnWidth(.65)},headers:['#','Description','Qty','Rate',if(gst)...['Taxable','GST %','GST'],'Total'],data:List.generate(lines.length,(i){final l=lines[i];final base=(l['price'] as num)*(l['qty'] as num);final tax=base*(l['gst'] as num)/100;return [i+1,l['name'],l['qty'],amount(l['price'] as num),if(gst)...[amount(base),l['gst'],amount(tax)],amount(base+tax)];})),
 pw.SizedBox(height:16),
 if(template==4)...[total(),pw.SizedBox(height:12),taxSummary(),payment()]else if(template==5)...[pw.Row(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[pw.Expanded(child:total()),pw.SizedBox(width:20),pw.Expanded(child:payment())]),taxSummary()]else ...[pw.Row(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[pw.Expanded(child:template==3?payment():taxSummary()),pw.SizedBox(width:16),pw.Expanded(child:total())]),pw.SizedBox(height:12),if(template==3)taxSummary()else payment()],
 if(terms.isNotEmpty)...[pw.SizedBox(height:16),label('TERMS & CONDITIONS'),pw.SizedBox(height:6),pw.Text(terms,style:const pw.TextStyle(fontSize:10))],pw.SizedBox(height:20),pw.Align(alignment:pw.Alignment.centerRight,child:pw.Container(width:180,padding:const pw.EdgeInsets.all(10),decoration:pw.BoxDecoration(border:pw.Border.all(color:PdfColors.grey400)),child:pw.Column(children:[pw.Text('For $business'),pw.SizedBox(height:30),pw.Divider(color:accent),pw.Text('Authorized Signatory')])))]));
 final bytes=await doc.save();if(!mounted)return;
 await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>Scaffold(appBar:AppBar(title:Text('${r['number']}')),body:PdfPreview(build:(_) async=>bytes,pdfFileName:'${r['number']}.pdf',canChangePageFormat:false,canChangeOrientation:false))));
 }catch(e){message('PDF error: $e');}}
 Widget heading(String title,String sub)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight:FontWeight.w800)),const SizedBox(height:5),Text(sub,style:Theme.of(context).textTheme.bodyMedium)]);
 Widget metric(String title,String value,IconData icon,Color color)=>Card(elevation:0,child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[CircleAvatar(radius:18,backgroundColor:color.withValues(alpha:.13),foregroundColor:color,child:Icon(icon,size:20)),const SizedBox(height:6),Expanded(child:Align(alignment:Alignment.centerLeft,child:Text(title,maxLines:2,overflow:TextOverflow.ellipsis))),const SizedBox(height:4),FittedBox(fit:BoxFit.scaleDown,child:Text(value,style:const TextStyle(fontSize:23,fontWeight:FontWeight.bold)))])));
 Widget saleTile(Map<String,Object?> r)=>Card(elevation:0,child:ListTile(leading:const CircleAvatar(child:Icon(Icons.receipt_long_outlined)),title:Text('${r['number']}'),subtitle:Text('${r['customer']} • ${DateFormat('dd MMM, HH:mm').format(DateTime.parse(r['date'] as String))}'),trailing:Text(money(r['total'] as num),style:const TextStyle(fontWeight:FontWeight.bold)),onTap:()=>invoice(r)));
 List<Widget> dashboard(){final today=DateTime.now().toIso8601String().substring(0,10);final daily=sales.where((r)=>(r['date'] as String).startsWith(today));return [heading('Business overview','Your business, at a glance'),const SizedBox(height:18),Container(padding:const EdgeInsets.all(24),decoration:BoxDecoration(gradient:LinearGradient(colors:[Theme.of(context).colorScheme.primary,Theme.of(context).colorScheme.primary.withValues(alpha:.8)]),borderRadius:BorderRadius.circular(24)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('TODAY’S REVENUE',style:TextStyle(color:Colors.white70,letterSpacing:1.5)),const SizedBox(height:12),Text(money(daily.fold<num>(0,(s,r)=>s+(r['total'] as num))),style:const TextStyle(color:Colors.white,fontSize:32,fontWeight:FontWeight.bold)),const SizedBox(height:16),FilledButton.tonalIcon(onPressed:()=>go(2),icon:const Icon(Icons.add),label:const Text('New invoice'))])),const SizedBox(height:12),GridView.count(crossAxisCount:2,shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),mainAxisExtent:180,crossAxisSpacing:10,mainAxisSpacing:8,children:[metric('Invoices today','${daily.length}',Icons.receipt_long,Colors.blue),metric('Products','${products.length}',Icons.inventory_2,Colors.deepPurple),metric('Low stock','${products.where((r)=>(r['qty'] as int)<=5).length}',Icons.warning_amber,Colors.orange),metric('Customers','${clients.length}',Icons.people,Colors.teal)]),const SizedBox(height:20),metricWide(),const SizedBox(height:16),weeklyChart(),const SizedBox(height:16),Text('Recent invoices',style:Theme.of(context).textTheme.titleLarge),if(sales.isEmpty)const Padding(padding:EdgeInsets.all(20),child:Text('No invoices yet')),...sales.take(5).map(saleTile)];}
 Widget metricWide()=>Card(child:Padding(padding:const EdgeInsets.all(18),child:Row(children:[const CircleAvatar(child:Icon(Icons.account_balance_wallet_outlined)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Stock value • selling price, ex GST'),Text(money(products.fold<num>(0,(a,r)=>a+(r['price'] as num)*(r['qty'] as num))),style:Theme.of(context).textTheme.titleLarge)]))])));
 Widget weeklyChart(){final now=DateTime.now();final days=List.generate(7,(i)=>DateTime(now.year,now.month,now.day-6+i));final values=days.map((d)=>sales.where((r)=>(r['date'] as String).startsWith(DateFormat('yyyy-MM-dd').format(d))).fold<double>(0,(a,r)=>a+(r['total'] as num).toDouble())).toList();final peak=values.fold<double>(1,(a,b)=>max(a,b));return Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('Sales • last 7 days',style:Theme.of(context).textTheme.titleMedium),Text(money(values.fold<double>(0,(a,b)=>a+b))),const SizedBox(height:16),Row(crossAxisAlignment:CrossAxisAlignment.end,children:List.generate(7,(i)=>Expanded(child:Column(children:[Tooltip(message:money(values[i]),child:Container(height:4+100*values[i]/peak,width:20,decoration:BoxDecoration(color:Theme.of(context).colorScheme.primary,borderRadius:BorderRadius.circular(6)))),const SizedBox(height:8),Text(DateFormat('E').format(days[i]),style:const TextStyle(fontSize:11))]))))])));}
 Widget searchBox()=>TextField(key:ValueKey(tab),onChanged:(s)=>setState(()=>search=s.toLowerCase()),decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:'Search records',filled:true,border:OutlineInputBorder(borderRadius:BorderRadius.circular(18),borderSide:BorderSide.none)));
 List<Widget> records(bool product){final rows=product?products:clients;final filtered=rows.where((r)=>r.values.join(' ').toLowerCase().contains(search)&&(!product||((category=='All'||r['category']==category)&&(!lowOnly||(r['qty'] as int)<=5))));return [heading(product?'Inventory':'Customers',product?'Manage products and stock':'Manage customer relationships'),const SizedBox(height:16),searchBox(),if(product) Wrap(spacing:8,children:[FilterChip(label:const Text('Low stock'),selected:lowOnly,onSelected:(v)=>setState(()=>lowOnly=v)),DropdownButton<String>(value:category,items:{'All',...products.map((r)=>(r['category']??'General').toString()),category}.map((v)=>DropdownMenuItem(value:v,child:Text(v.isEmpty?'Uncategorized':v))).toList(),onChanged:(v)=>setState(()=>category=v??'All'))]),const SizedBox(height:12),FilledButton.icon(onPressed:()=>edit(product),icon:const Icon(Icons.add),label:Text(product?'Add product':'Add customer')),if(filtered.isEmpty)const Padding(padding:EdgeInsets.all(32),child:Center(child:Text('No records found'))),...filtered.map((r)=>Card(elevation:0,child:ListTile(leading:CircleAvatar(child:Icon(product?Icons.inventory_2_outlined:Icons.person_outline)),title:Text('${r['name']}'),subtitle:Text(product?'${r['code']} • ${r['qty']} in stock • ${r['category']??'General'}':'${r['phone']} • ${r['address']}'),onTap:()=>edit(product,r),trailing:product?Column(mainAxisAlignment:MainAxisAlignment.center,children:[Text(money(r['price'] as num)),if((r['qty'] as int)<=5)const Text('LOW STOCK',style:TextStyle(color:Colors.orange,fontSize:10,fontWeight:FontWeight.bold))]):const Icon(Icons.edit_outlined))))];}
 List<Widget> pos()=>[heading('New sale','Select products and review your cart'),const SizedBox(height:16),DropdownButtonFormField<int>(value:client,decoration:const InputDecoration(labelText:'Customer',border:OutlineInputBorder()),items:[const DropdownMenuItem<int>(value:null,child:Text('Walk-in customer')),...clients.map((r)=>DropdownMenuItem<int>(value:r['id'] as int,child:Text('${r['name']}')))],onChanged:busy?null:(v)=>setState(()=>client=v)),const SizedBox(height:12),searchBox(),if(products.isEmpty)TextButton(onPressed:()=>go(1),child:const Text('Add products first')),...products.where((r)=>r.values.join(' ').toLowerCase().contains(search)).map((r){final id=r['id'] as int;final q=cart[id]??0;return Card(elevation:0,child:ListTile(title:Text('${r['name']}'),subtitle:Text('${money(r['price'] as num)} + ${r['gst']}% GST'),trailing:Row(mainAxisSize:MainAxisSize.min,children:[IconButton(onPressed:busy||q==0?null:()=>setState(()=>cart[id]=q-1),icon:const Icon(Icons.remove_circle_outline)),Text('$q'),IconButton(onPressed:busy||q>=(r['qty'] as int)?null:()=>setState(()=>cart[id]=q+1),icon:const Icon(Icons.add_circle))])));}),const SizedBox(height:16),Text('Cart total  ${money(cartTotal)}',style:Theme.of(context).textTheme.titleLarge),FilledButton.icon(onPressed:busy||!cart.values.any((q)=>q>0)?null:checkout,icon:const Icon(Icons.check),label:const Text('Save invoice'))];
 @override Widget build(BuildContext context){final pages=[dashboard,()=>records(true),pos,()=>[heading('Invoices','Search, preview or share invoices'),const SizedBox(height:12),searchBox(),...sales.where((r)=>r.values.join(' ').toLowerCase().contains(search)).map(saleTile)],()=>[heading('Settings','MR Vision Tech'),ListTile(leading:const Icon(Icons.people_outline),title:const Text('Customers'),onTap:()=>go(5)),ListTile(leading:const Icon(Icons.palette_outlined),title:const Text('Appearance & Themes'),onTap:()=>Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>ThemePage(settings:widget.settings,save:widget.save)))),ListTile(leading:const Icon(Icons.business),title:const Text('Business & Invoice Settings'),onTap:()=>Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>ConfigPage(settings:widget.settings,save:widget.save)))),ListTile(leading:const Icon(Icons.description_outlined),title:const Text('Invoice Templates (A4)'),onTap:() async {final choice=await showDialog<int>(context:context,builder:(ctx)=>SimpleDialog(title:const Text('Select A4 template'),children:List.generate(6,(i)=>SimpleDialogOption(onPressed:()=>Navigator.pop(ctx,i),child:Text(['Classic Monochrome','Tally Professional','MR Vision Compact','Corporate Blue','Premium Gold','Modern Premium'][i])))));if(choice!=null)await widget.save('invoice_template',choice.toString());}),ListTile(leading:const Icon(Icons.backup_outlined),title:const Text('Backup & Restore'),subtitle:const Text('Export or restore business data'),onTap:() async {await Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>BackupPage(db:widget.db,onRestored:() async {cart.clear();client=null;category='All';lowOnly=false;await widget.reloadSettings();await refresh();})));}),SwitchListTile(title:const Text('Dark mode'),value:widget.dark,onChanged:(_)=>widget.toggle()),ListTile(leading:const Icon(Icons.info_outline),title:const Text('About ERP'),subtitle:const Text('MR Vision Tech • Offline edition 3.2.3'),onTap:()=>Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>const DeveloperAboutPage())))],()=>records(false)];return PopScope<Object?>(canPop:false,onPopInvokedWithResult:(didPop,result){if(!didPop)back();},child:Scaffold(appBar:AppBar(backgroundColor:Theme.of(context).colorScheme.primary,foregroundColor:Theme.of(context).colorScheme.onPrimary,title:Row(children:[ClipRRect(borderRadius:BorderRadius.circular(8),child:Image.asset('assets/logo.png',width:40,height:40)),const SizedBox(width:12),const Text('MR Vision Tech',style:TextStyle(fontWeight:FontWeight.bold))]),actions:[IconButton(onPressed:()=>go(5),icon:const Icon(Icons.people_outline),tooltip:'Customers')]),body:SafeArea(child:ListView(key:ValueKey(tab),padding:const EdgeInsets.all(16),children:pages[tab]())),bottomNavigationBar:NavigationBar(selectedIndex:tab==5?4:tab,onDestinationSelected:go,destinations:const [NavigationDestination(icon:Icon(Icons.dashboard_outlined),label:'Home'),NavigationDestination(icon:Icon(Icons.inventory_2_outlined),label:'Stock'),NavigationDestination(icon:Icon(Icons.shopping_cart_outlined),label:'POS'),NavigationDestination(icon:Icon(Icons.receipt_long_outlined),label:'Sales'),NavigationDestination(icon:Icon(Icons.settings_outlined),label:'More')])));}
}

class _RecordDialog extends StatefulWidget {
 final bool product; final Map<String,Object?>? record;
 const _RecordDialog({required this.product,this.record});
 @override State<_RecordDialog> createState()=>_RecordDialogState();
}
class _RecordDialogState extends State<_RecordDialog> {
 late final List<TextEditingController> cs;
 @override void initState(){super.initState();final keys=widget.product?['code','name','price','qty','gst','cost','category','barcode']:['name','phone','address'];cs=keys.map((k)=>TextEditingController(text:widget.record?[k]?.toString()??'')).toList();if(widget.product&&widget.record==null){cs[0].text='MR-${Random.secure().nextInt(0x10000).toRadixString(16).padLeft(4,'0').toUpperCase()}';cs[3].text='0';cs[4].text='0';cs[6].text='General';}}
 @override void dispose(){for(final c in cs){c.dispose();}super.dispose();}
 Widget field(String label,TextEditingController c,{bool numeric=false})=>Padding(padding:const EdgeInsets.only(bottom:14),child:TextField(controller:c,keyboardType:numeric?const TextInputType.numberWithOptions(decimal:true):TextInputType.text,decoration:InputDecoration(labelText:label,border:OutlineInputBorder(borderRadius:BorderRadius.circular(14)))));
 @override Widget build(BuildContext context)=>Scaffold(
 appBar:AppBar(title:Text(widget.record==null?(widget.product?'Add product':'Add customer'):(widget.product?'Edit product':'Edit customer'))),
 body:SafeArea(child:ListView(padding:const EdgeInsets.all(20),children:[Text(widget.product?'Product information':'Customer information',style:Theme.of(context).textTheme.titleLarge),const SizedBox(height:16),...List.generate(cs.length,(i)=>field((widget.product?['Item code','Product name','Selling price before GST','Stock quantity','GST %','Purchase price (optional)','Category','Barcode']:['Name','Phone','Address'])[i],cs[i],numeric:widget.product&&i>=2&&i<=5)),FilledButton.icon(onPressed:()=>Navigator.of(context).pop(cs.map((c)=>c.text.trim()).toList()),icon:const Icon(Icons.save_outlined),label:const Text('Save record'))])));
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
   const Text('MR Vision Tech • Offline Edition 3.2.3',textAlign:TextAlign.center),
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
    'products':['id','code','name','price','qty','gst','cost','category','barcode'],
    'clients':['id','name','phone','address'],
    'sales':['id','number','date','customer','total'],
    'lines':['id','sale','name','qty','price','gst','cost'],
    'preferences':['k','v'],
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
    final bytes=Uint8List.fromList(utf8.encode(jsonEncode({'format':'mr-vision-tech-backup','schema':2,'created':DateTime.now().toIso8601String(),'tables':tables})));
    final path=await FilePicker.platform.saveFile(dialogTitle:'Save backup outside the app',fileName:'MR_Vision_Tech_Backup_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.json',type:FileType.custom,allowedExtensions:['json'],bytes:bytes);
    if(mounted)setState(()=>status=path==null?'Backup cancelled':'Backup exported. Keep this file in Downloads or another safe folder.');
    return path!=null;
  }
  Map<String,List<Map<String,Object?>>> validate(Object? raw){
    if(raw is! Map || raw['format']!='mr-vision-tech-backup'||raw['schema']!=2||raw['tables'] is! Map){throw const FormatException('Unsupported backup format');}
    final tables=raw['tables'] as Map;
    final result=<String,List<Map<String,Object?>>>{};
    for(final entry in columns.entries){
      final rows=tables[entry.key];
      if(rows is! List)throw FormatException('Missing table: ${entry.key}');
      final records=<Map<String,Object?>>[];
      final ids=<Object?>{};
      for(final row in rows){
        if(row is! Map || row.length!=entry.value.length || !entry.value.every((c)=>row.containsKey(c)))throw FormatException('Invalid columns: ${entry.key}');
        final record=Map<String,Object?>.from(row);
        for(final c in entry.value){
          final v=record[c];
          if(['id','sale','qty'].contains(c)){if(v is! int || v<(c=='qty'?0:1))throw FormatException('Invalid $c');}
          else if(['price','gst','cost','total'].contains(c)){if(v==null&&c=='cost')continue;if(v is! num||!v.isFinite||v<0||(c=='gst'&&v>100))throw FormatException('Invalid $c');}
          else if(v is! String && !(v==null&&['phone','address','category','barcode'].contains(c)))throw FormatException('Invalid $c');
        }
        if(!ids.add(record[entry.key=='preferences'?'k':'id']))throw const FormatException('Duplicate record');
        if(entry.key=='sales'&&DateTime.tryParse(record['date'] as String)==null)throw const FormatException('Invalid invoice date');
        records.add(record);
      }
      result[entry.key]=records;
    }
    final saleIds=result['sales']!.map((r)=>r['id']).toSet();
    if(result['lines']!.any((r)=>!saleIds.contains(r['sale'])))throw const FormatException('Invoice lines without invoice');
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
      for(final table in columns.keys){for(final row in data[table]!){await tx.insert(table,row);}}
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
