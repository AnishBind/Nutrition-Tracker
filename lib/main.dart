// main.dart — Nutrition Tracker (fixed & hardened)
// - Robust save flow after detection
// - Clear snackbars on success/failure
// - Consistent DB schema (entries table) with 'fats' column
// - Safer number parsing & null handling
// - Pie chart per-day + CSV export + manual add
// - Parallel Roboflow calls with tie-break on confidence

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:csv/csv.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NutritionApp());
}

class NutritionApp extends StatelessWidget {
  const NutritionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nutrition Tracker',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.green,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.green,
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}

/* -------------------------
 Database helper (sqflite)
-------------------------*/
class DbHelper {
  static Database? _db;

  static Future<Database> db() async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'nutrition_tracker.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
        CREATE TABLE entries(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT,
          calories REAL,
          protein REAL,
          carbs REAL,
          fats REAL,
          date TEXT,
          imagePath TEXT,
          grams REAL
        )
      ''');
      },
    );
    return _db!;
  }

  static Future<int> insertEntry(Map<String, Object?> row) async {
    final d = await db();
    return d.insert('entries', row);
  }

  static Future<int> deleteEntry(int id) async {
    final d = await db();
    return d.delete('entries', where: 'id = ?', whereArgs: [id]);
  }

  static Future<List<Map<String, dynamic>>> fetchAllEntries() async {
    final d = await db();
    final rows = await d.query('entries', orderBy: 'date DESC, id DESC');
    return rows;
  }
}

/* -------------------------
 Food JSON model
-------------------------*/
class FoodInfo {
  final String name;
  final String unit; // "g" | "piece"
  final double defaultWeightG;
  final double calories; // for defaultWeightG
  final double proteinG; // for defaultWeightG
  final double carbsG; // for defaultWeightG
  final double fatG; // for defaultWeightG

  FoodInfo({
    required this.name,
    required this.unit,
    required this.defaultWeightG,
    required this.calories,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
  });

  factory FoodInfo.fromMap(Map<String, dynamic> m) => FoodInfo(
    name: (m['name'] ?? '').toString().toLowerCase(),
    unit: (m['unit'] ?? 'g').toString().toLowerCase(),
    defaultWeightG: ((m['default_weight_g'] ?? 100) as num).toDouble(),
    calories: ((m['calories'] ?? 0) as num).toDouble(),
    proteinG: ((m['protein_g'] ?? 0) as num).toDouble(),
    carbsG: ((m['carbs_g'] ?? 0) as num).toDouble(),
    fatG: ((m['fat_g'] ?? 0) as num).toDouble(),
  );
}

/* -------------------------
 Nutrition calc helpers
-------------------------*/
class NutritionCalc {
  /// Scale nutrition values from default weight to any grams
  static Map<String, double> scaleFromDefault(FoodInfo info, double grams) {
    final f = grams / info.defaultWeightG;
    return {
      'calories': info.calories * f,
      'protein': info.proteinG * f,
      'carbs': info.carbsG * f,
      'fat': info.fatG * f,
    };
  }
}

/* -------------------------
 Roboflow Multiple Models
-------------------------*/
class RoboflowConfig {
  static const apiKey = '6q3DhGakosBH7b8BMQSx';

  // (One bad id may fail — handled)
  static const List<String> modelIds = [
    'indian-food-vitsx/3',
    'indian-food-jwife/2',
    'indian-food-jwife/2',
    'indian-food-huqdn/1',
    'indian-food-dca77/1',
    'indian-food-clzdq/1',
    'indian-food-iubji/1',
    'south-indian-food-detection/3',
    'indian-food-detection-kzw9g/1',
    'indian-food-detection-5jphr/5',
    'indian-food-classifier-pr7rf/1',
    '-food-detection/1', // will fail gracefully
    'food-detection-pgfas/2',
    'food-4oq56/1',
    'food-detection-rq1n2/1',
  ];

  static Uri buildUri(String modelId) =>
      Uri.parse('https://detect.roboflow.com/$modelId?api_key=$apiKey');
}

/* -------------------------
 HomeScreen
-------------------------*/
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, List<Map<String, dynamic>>> grouped = {};
  bool loading = true;
  Map<String, FoodInfo> foodMap = {};
  bool jsonLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadFoodJson().then((_) => _refresh());
  }

  Future<void> _loadFoodJson() async {
    try {
      final raw = await rootBundle.loadString('assets/food_data.json');
      final List<dynamic> arr = json.decode(raw);
      final Map<String, FoodInfo> map = {
        for (final m in arr)
          (m['name']?.toString().toLowerCase() ?? ''): FoodInfo.fromMap(m),
      };
      foodMap = map;
      jsonLoaded = true;
    } catch (e) {
      jsonLoaded = false;
      debugPrint('food_data.json load error: $e');
    }
  }

  Future<void> _refresh() async {
    setState(() => loading = true);
    final rows = await DbHelper.fetchAllEntries();
    final Map<String, List<Map<String, dynamic>>> map = {};
    for (var r in rows) {
      final d = (r['date'] as String);
      map.putIfAbsent(d, () => []).add(r);
    }
    setState(() {
      grouped = map;
      loading = false;
    });
  }

  Map<String, double> _totalsForDate(String date) {
    final list = grouped[date] ?? [];
    double cal = 0, prot = 0, carbs = 0, fats = 0;
    for (var e in list) {
      cal += (e['calories'] as num).toDouble();
      prot += (e['protein'] as num).toDouble();
      carbs += (e['carbs'] as num).toDouble();
      fats += (e['fats'] as num).toDouble();
    }
    return {'cal': cal, 'protein': prot, 'carbs': carbs, 'fats': fats};
  }

  Future<void> _exportCsv() async {
    final rows = <List<dynamic>>[];
    rows.add(['date', 'name', 'grams', 'calories', 'protein', 'carbs', 'fats']);
    final dates = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    for (var date in dates) {
      for (var e in grouped[date]!) {
        rows.add([
          date,
          e['name'],
          (e['grams'] as num?)?.toDouble() ?? 0,
          (e['calories'] as num?)?.toDouble() ?? 0,
          (e['protein'] as num?)?.toDouble() ?? 0,
          (e['carbs'] as num?)?.toDouble() ?? 0,
          (e['fats'] as num?)?.toDouble() ?? 0,
        ]);
      }
    }
    final csv = const ListToCsvConverter().convert(rows);
    final tmp = await getTemporaryDirectory();
    final file = File(p.join(
        tmp.path, 'nutrition_export_${DateTime.now().toIso8601String()}.csv'));
    await file.writeAsString(csv);
    Share.shareXFiles([XFile(file.path)], text: 'Nutrition export');
  }

  Future<void> _confirmDelete(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete entry?'),
        content: const Text('This will remove the entry permanently.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await DbHelper.deleteEntry(id);
      await _refresh();
    }
  }

  String _formatDateHeader(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final other = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(other).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${dt.day.toString().padLeft(2, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.year}';
  }

  Widget _buildPieForDate(String date) {
    final t = _totalsForDate(date);
    final total =
        (t['cal'] ?? 0) + (t['protein'] ?? 0) + (t['carbs'] ?? 0) + (t['fats'] ?? 0);
    if (total <= 0) return const SizedBox.shrink();
    return SizedBox(
      height: 160,
      child: PieChart(
        PieChartData(
          sectionsSpace: 2,
          centerSpaceRadius: 28,
          sections: [
            PieChartSectionData(
              value: t['cal']!,
              title: 'Cal',
              color: Colors.redAccent,
              radius: 54,
              titleStyle: const TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
            ),
            PieChartSectionData(
              value: t['protein']!,
              title: 'P',
              color: Colors.green,
              radius: 54,
              titleStyle: const TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
            ),
            PieChartSectionData(
              value: t['carbs']!,
              title: 'C',
              color: Colors.blueAccent,
              radius: 54,
              titleStyle: const TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
            ),
            PieChartSectionData(
              value: t['fats']!,
              title: 'F',
              color: Colors.orange,
              radius: 54,
              titleStyle: const TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateCard(String date) {
    final totals = _totalsForDate(date);
    final list = grouped[date]!;
    final dt = DateTime.parse(date);
    final title = _formatDateHeader(dt);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Text(title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          elevation: 2,
          shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(children: [
              _buildPieForDate(date),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _StatTile(
                      label: 'Calories',
                      value: '${totals['cal']!.toStringAsFixed(0)} kcal'),
                  _StatTile(
                      label: 'Protein',
                      value: '${totals['protein']!.toStringAsFixed(1)} g'),
                  _StatTile(
                      label: 'Carbs',
                      value: '${totals['carbs']!.toStringAsFixed(1)} g'),
                  _StatTile(
                      label: 'Fats',
                      value: '${totals['fats']!.toStringAsFixed(1)} g'),
                ],
              ),
              const Divider(height: 18),
              ListView.separated(
                physics: const NeverScrollableScrollPhysics(),
                shrinkWrap: true,
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, idx) {
                  final e = list[idx];
                  return ListTile(
                    leading: (e['imagePath'] != null && (e['imagePath'] as String).isNotEmpty)
                        ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(File(e['imagePath']),
                          width: 56, height: 56, fit: BoxFit.cover),
                    )
                        : CircleAvatar(
                      backgroundColor: Colors.green.shade100,
                      child: Text(
                        (e['name'] ?? '?')
                            .toString()
                            .isNotEmpty
                            ? e['name'][0].toUpperCase()
                            : '?',
                        style: const TextStyle(color: Colors.green),
                      ),
                    ),
                    title: Text(e['name'],
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        '${((e['grams'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)} g • '
                            '${(e['calories'] as num).toStringAsFixed(0)} kcal • '
                            'P ${(e['protein'] as num).toStringAsFixed(1)}g • '
                            'C ${(e['carbs'] as num).toStringAsFixed(1)}g • '
                            'F ${(e['fats'] as num).toStringAsFixed(1)}g'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _confirmDelete(e['id'] as int),
                    ),
                  );
                },
              )
            ]),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final dates = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nutrition Tracker'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'Export CSV',
            onPressed: grouped.isEmpty ? null : _exportCsv,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refresh,
          )
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : (grouped.isEmpty
          ? Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.food_bank, size: 64, color: Colors.green.shade300),
            const SizedBox(height: 12),
            const Text('No entries yet', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 6),
            const Text('Tap + to add your first food'),
          ]))
          : RefreshIndicator(
        onRefresh: _refresh,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          child: Column(
            children: dates.map((d) => _buildDateCard(d)).toList(),
          ),
        ),
      )),
      floatingActionButton: _Fab(foodMap: foodMap, onAdded: _refresh),
    );
  }
}

class _Fab extends StatelessWidget {
  final Map<String, FoodInfo> foodMap;
  final Future<void> Function() onAdded;
  const _Fab({required this.foodMap, required this.onAdded});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Add',
      position: PopupMenuPosition.under,
      onSelected: (v) async {
        if (v == 'manual') {
          final added = await Navigator.push<bool>(
              context,
              MaterialPageRoute(
                  builder: (_) => AddEntryPage(foodMap: foodMap)));
          if (added == true) await onAdded();
        } else {
          final added = await Navigator.push<bool>(
              context,
              MaterialPageRoute(
                  builder: (_) => DetectAutoPage(foodMap: foodMap)));
          if (added == true) await onAdded();
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
            value: 'manual',
            child: ListTile(
                leading: Icon(Icons.edit_note_outlined),
                title: Text('Add manually'))),
        PopupMenuItem(
            value: 'detect',
            child: ListTile(
                leading: Icon(Icons.camera_alt_outlined),
                title: Text('Detect from photo (auto)'))),
      ],
      child: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: null,
      ),
    );
  }
}

/* -------------------------
 Small UI helpers
-------------------------*/
class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  const _StatTile({required this.label, required this.value, super.key});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text(label,
          style: TextStyle(
              fontSize: 12, color: Theme.of(context).textTheme.bodySmall?.color)),
    ]);
  }
}

/* -------------------------
 AddEntryPage (manual add) using food_data.json
-------------------------*/
class AddEntryPage extends StatefulWidget {
  final Map<String, FoodInfo> foodMap;
  const AddEntryPage({super.key, required this.foodMap});

  @override
  State<AddEntryPage> createState() => _AddEntryPageState();
}

class _AddEntryPageState extends State<AddEntryPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _gramsCtrl = TextEditingController(text: '100');
  final _calCtrl = TextEditingController();
  final _protCtrl = TextEditingController();
  final _carbCtrl = TextEditingController();
  final _fatCtrl = TextEditingController();

  DateTime selectedDate = DateTime.now();
  File? _image;
  final ImagePicker _picker = ImagePicker();
  bool saving = false;

  Future<void> _pick(ImageSource src) async {
    try {
      final XFile? f = await _picker.pickImage(source: src, maxWidth: 1200);
      if (f == null) return;
      setState(() => _image = File(f.path));
    } catch (e) {
      debugPrint('Image pick error: $e');
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Image pick error')));
    }
  }

  Future<void> _openLocalPicker() async {
    final list = widget.foodMap.keys.toList()..sort();
    final selected = await showDialog<String?>(
      context: context,
      builder: (context) {
        String query = '';
        return StatefulBuilder(builder: (context, setSB) {
          final shown = list
              .where((e) => e.toLowerCase().contains(query.toLowerCase()))
              .toList();
          return AlertDialog(
            title: const Text('Pick food from list'),
            content: SizedBox(
              width: double.maxFinite,
              height: 420,
              child: Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Search food...'),
                    onChanged: (v) => setSB(() => query = v),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.separated(
                      itemCount: shown.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (c, i) => ListTile(
                        title: Text(shown[i]),
                        onTap: () => Navigator.pop(context, shown[i]),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('Cancel')),
            ],
          );
        });
      },
    );
    if (selected != null) {
      final info = widget.foodMap[selected]!;
      final grams = info.defaultWeightG;
      final scaled = NutritionCalc.scaleFromDefault(info, grams);
      setState(() {
        _nameCtrl.text = info.name;
        _gramsCtrl.text = grams.toStringAsFixed(0);
        _calCtrl.text = scaled['calories']!.toStringAsFixed(0);
        _protCtrl.text = scaled['protein']!.toStringAsFixed(1);
        _carbCtrl.text = scaled['carbs']!.toStringAsFixed(1);
        _fatCtrl.text = scaled['fat']!.toStringAsFixed(1);
      });
    }
  }

  Future<void> _recalcFromGrams() async {
    final name = _nameCtrl.text.trim().toLowerCase();
    if (name.isEmpty || !widget.foodMap.containsKey(name)) return;
    final grams = double.tryParse(_gramsCtrl.text.trim()) ?? 100;
    final info = widget.foodMap[name]!;
    final scaled = NutritionCalc.scaleFromDefault(info, grams);
    setState(() {
      _calCtrl.text = scaled['calories']!.toStringAsFixed(0);
      _protCtrl.text = scaled['protein']!.toStringAsFixed(1);
      _carbCtrl.text = scaled['carbs']!.toStringAsFixed(1);
      _fatCtrl.text = scaled['fat']!.toStringAsFixed(1);
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => saving = true);
    String? savedPath;
    try {
      if (_image != null) {
        final dir = await getApplicationDocumentsDirectory();
        final filename =
            'img_${DateTime.now().millisecondsSinceEpoch}${p.extension(_image!.path)}';
        final dest = File(p.join(dir.path, filename));
        await dest.writeAsBytes(await _image!.readAsBytes());
        savedPath = dest.path;
      }

      final row = {
        'name': _nameCtrl.text.trim(),
        'grams': double.tryParse(_gramsCtrl.text.trim()) ?? 0.0,
        'calories': double.tryParse(_calCtrl.text.trim()) ?? 0.0,
        'protein': double.tryParse(_protCtrl.text.trim()) ?? 0.0,
        'carbs': double.tryParse(_carbCtrl.text.trim()) ?? 0.0,
        'fats': double.tryParse(_fatCtrl.text.trim()) ?? 0.0,
        'date': _formatDate(selectedDate),
        'imagePath': savedPath ?? '',
      };
      await DbHelper.insertEntry(row);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Entry saved successfully')));
        Navigator.pop(context, true);
      }
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'
          .trim();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _calCtrl.dispose();
    _protCtrl.dispose();
    _carbCtrl.dispose();
    _fatCtrl.dispose();
    _gramsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Add Food Entry')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: ListView(
          children: [
            GestureDetector(
              onTap: () async {
                showModalBottomSheet(
                    context: context,
                    builder: (_) => SafeArea(
                      child: Wrap(
                        children: [
                          ListTile(
                              leading: const Icon(Icons.camera_alt),
                              title: const Text('Camera'),
                              onTap: () {
                                Navigator.pop(context);
                                _pick(ImageSource.camera);
                              }),
                          ListTile(
                              leading: const Icon(Icons.photo),
                              title: const Text('Gallery'),
                              onTap: () {
                                Navigator.pop(context);
                                _pick(ImageSource.gallery);
                              }),
                        ],
                      ),
                    ));
              },
              child: _image == null
                  ? Container(
                height: 160,
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: theme.cardColor),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.camera_alt_outlined,
                        size: 36, color: Colors.green.shade400),
                    const SizedBox(height: 8),
                    const Text('Add photo (optional)',
                        style: TextStyle(fontSize: 14))
                  ]),
                ),
              )
                  : ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(_image!,
                    height: 160, width: double.infinity, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 12),
            Form(
              key: _formKey,
              child: Column(children: [
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _nameCtrl,
                        decoration: InputDecoration(
                          labelText: 'Food name',
                          suffixIcon: IconButton(
                            tooltip: 'Pick from list',
                            icon: const Icon(Icons.list_alt_outlined),
                            onPressed: _openLocalPicker,
                          ),
                        ),
                        validator: (v) =>
                        (v == null || v.trim().isEmpty)
                            ? 'Enter food name'
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _gramsCtrl,
                      decoration:
                      const InputDecoration(labelText: 'Quantity (grams)'),
                      keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => _recalcFromGrams(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _calCtrl,
                      decoration:
                      const InputDecoration(labelText: 'Calories (kcal)'),
                      keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _protCtrl,
                      decoration: const InputDecoration(labelText: 'Protein (g)'),
                      keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _carbCtrl,
                      decoration: const InputDecoration(labelText: 'Carbs (g)'),
                      keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _fatCtrl,
                      decoration: const InputDecoration(labelText: 'Fats (g)'),
                      keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Text('Date: ${selectedDate.day}-${selectedDate.month}-${selectedDate.year}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                  TextButton.icon(
                      onPressed: () async {
                        final d = await showDatePicker(
                            context: context,
                            initialDate: selectedDate,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100));
                        if (d != null) setState(() => selectedDate = d);
                      },
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: const Text('Change'))
                ]),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                      onPressed: saving ? null : _save,
                      style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14)),
                      child: saving
                          ? const CircularProgressIndicator()
                          : const Text('Save Entry')),
                )
              ]),
            )
          ],
        ),
      ),
    );
  }
}

/* -------------------------
 DetectAutoPage (single final detection by voting)
-------------------------*/
class DetectAutoPage extends StatefulWidget {
  final Map<String, FoodInfo> foodMap;
  const DetectAutoPage({super.key, required this.foodMap});

  @override
  State<DetectAutoPage> createState() => _DetectAutoPageState();
}

class _DetectAutoPageState extends State<DetectAutoPage> {
  final ImagePicker _picker = ImagePicker();
  File? _image;
  bool _detecting = false;

  Future<void> _pick(ImageSource src) async {
    try {
      final XFile? f = await _picker.pickImage(source: src, maxWidth: 1400);
      if (f == null) return;
      setState(() {
        _image = File(f.path);
      });
      await _detectAndResolve(_image!);
    } catch (e) {
      debugPrint('pick error $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Image pick error')));
    }
  }

  Future<void> _detectAndResolve(File file) async {
    setState(() => _detecting = true);

    try {
      // 1) Parallel calls to all models
      final futures = <Future<http.StreamedResponse>>[];
      for (final modelId in RoboflowConfig.modelIds) {
        final uri = RoboflowConfig.buildUri(modelId);
        final req = http.MultipartRequest('POST', uri);
        try {
          req.files.add(await http.MultipartFile.fromPath('file', file.path));
        } catch (_) {}
        futures.add(req.send().timeout(const Duration(seconds: 18)));
      }

      final responses = await Future.wait(
        futures.map((f) => f.then((r) => r).catchError((_) => null)),
      );

      // 2) Collect predictions
      final Map<String, int> totalCount = {};
      final Map<String, double> maxConf = {};
      final Map<String, int> bestModelPieceCount = {};

      for (final r in responses) {
        if (r == null) continue;
        final body = await r.stream.bytesToString();
        if (r.statusCode != 200) continue;
        try {
          final decoded = json.decode(body);
          final preds = (decoded['predictions'] as List?) ?? [];

          final Map<String, int> perModelCount = {};
          for (final p in preds) {
            final cls = (p['class'] ?? '').toString().toLowerCase();
            final conf = ((p['confidence'] ?? 0) as num).toDouble();
            if (cls.isEmpty) continue;

            totalCount[cls] = (totalCount[cls] ?? 0) + 1;
            if (!maxConf.containsKey(cls) || maxConf[cls]! < conf) {
              maxConf[cls] = conf;
            }
            perModelCount[cls] = (perModelCount[cls] ?? 0) + 1;
          }

          perModelCount.forEach((cls, c) {
            if (!bestModelPieceCount.containsKey(cls) ||
                bestModelPieceCount[cls]! < c) {
              bestModelPieceCount[cls] = c;
            }
          });
        } catch (_) {}
      }

      if (totalCount.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No items detected. Pick manually.')));
        return;
      }

      // 3) Decide winner: highest count, tie -> highest maxConf
      String winner = totalCount.entries.reduce((a, b) {
        if (a.value != b.value) return a.value > b.value ? a : b;
        final ca = maxConf[a.key] ?? 0.0;
        final cb = maxConf[b.key] ?? 0.0;
        return ca >= cb ? a : b;
      }).key;

      final defaultPieces = bestModelPieceCount[winner] ?? 1;
      await _askQuantityAndSave(winner, defaultPieces, file);
    } catch (e) {
      debugPrint('detect error $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Detection failed. Try again.')));
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  Future<void> _askQuantityAndSave(
      String className, int defaultPieces, File img) async {
    final key = className.toLowerCase();
    final info = widget.foodMap[key];

    if (info == null) {
      await showDialog(
          context: context,
          builder: (_) => AlertDialog(
              title: const Text('Unknown food detected'),
            content: Text(
              'Detected: $className\n\nNot found in local database. Please add manually.',
            ),

            actions: [
                  TextButton(
                  onPressed: () => Navigator.pop(context),
          child: const Text('OK')),
    ],
    ),
    );
    return;
    }

    // Save image once
    String? savedPath;
    try {
    final dir = await getApplicationDocumentsDirectory();
    final filename =
    'img_${DateTime.now().millisecondsSinceEpoch}${p.extension(img.path)}';
    final dest = File(p.join(dir.path, filename));
    await dest.writeAsBytes(await img.readAsBytes());
    savedPath = dest.path;
    } catch (e) {
    // still allow save without image
    savedPath = '';
    }

    // Ask quantity
    final grams = await showDialog<double?>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
    final tc = TextEditingController();
    final unitLabel = info.unit == 'piece' ? 'pieces' : 'grams';
    if (info.unit == 'piece') {
    tc.text = defaultPieces.toString();
    } else {
    tc.text = info.defaultWeightG.toStringAsFixed(0);
    }
    return AlertDialog(
    title: Text('Confirm Quantity (${info.name})'),
    content: TextField(
    controller: tc,
    keyboardType:
    const TextInputType.numberWithOptions(decimal: true, signed: false),
    decoration: InputDecoration(hintText: 'Enter $unitLabel'),
    ),
    actions: [
    TextButton(
    onPressed: () => Navigator.pop(context, null),
    child: const Text('Cancel')),
    ElevatedButton(
    onPressed: () {
    final v = double.tryParse(tc.text.trim()) ?? 0;
    if (v <= 0) {
    Navigator.pop(context, null);
    return;
    }
    final g = info.unit == 'piece' ? (v * info.defaultWeightG) : v;
    Navigator.pop(context, g);
    },
    child: const Text('OK'),
    ),
    ],
    );
    },
    );

    if (grams == null || grams <= 0) {
    return; // user cancelled or invalid
    }

    try {
    // Compute nutrition & save
    final scaled = NutritionCalc.scaleFromDefault(info, grams);
    final row = {
    'name': info.name,
    'grams': grams,
    'calories': scaled['calories']!,
    'protein': scaled['protein']!,
    'carbs': scaled['carbs']!,
    'fats': scaled['fat']!, // DB column is 'fats'
    'date': _formatDate(DateTime.now()),
    'imagePath': savedPath ?? '',
    };
    await DbHelper.insertEntry(row);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Entry saved successfully')));
    Navigator.pop(context, true); // close DetectAutoPage and signal refresh
    } catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
        appBar: AppBar(title: const Text('Detect (Auto)')),
        body: Padding(
          padding: const EdgeInsets.all(12.0),
          child: ListView(
              children: [
              GestureDetector(
              onTap: () async {
        showModalBottomSheet(
        context: context,
        builder: (_) => SafeArea(
        child: Wrap(
        children: [
        ListTile(
        leading: const Icon(Icons.camera_alt),
        title: const Text('Camera'),
        onTap: () {
        Navigator.pop(context);
        _pick(ImageSource.camera);
        }),
        ListTile(
        leading: const Icon(Icons.photo),
        title: const Text('Gallery'),
        onTap: () {
        Navigator.pop(context);
        _pick(ImageSource.gallery);
        }),
        ],
        ),
        ));
        },
          child: _detecting
              ? Container(
            height: 160,
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: theme.cardColor),
            child: const Center(child: CircularProgressIndicator()),
          )
              : _image == null
              ? Container(
            height: 160,
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: theme.cardColor),
            child: Center(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.camera_alt_outlined,
                        size: 36, color: Colors.green.shade400),
                    const SizedBox(height: 8),
                    const Text('Tap to add image',
                        style: TextStyle(fontSize: 14)),
                  ]),
            ),
          )
              : ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(_image!,
                height: 160,
                width: double.infinity,
                fit: BoxFit.cover),
          ),
        ),

    ],
    ),
    ),
    );
  }
}
