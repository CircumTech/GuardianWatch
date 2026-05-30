import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/health_record.dart';

class LocalDbService {
  static Database? _db;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final path = join(await getDatabasesPath(), 'guardianwrist.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE health_records (
            id          TEXT PRIMARY KEY,
            user_id     TEXT NOT NULL,
            heart_rate  INTEGER NOT NULL,
            spo2        INTEGER NOT NULL,
            temperature REAL    NOT NULL,
            recorded_at TEXT    NOT NULL
          )
        ''');
      },
    );
  }

  Future<void> insertRecord(HealthRecord r) async {
    final d = await db;
    await d.insert('health_records', r.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<HealthRecord>> queryRecords({
    DateTime? from,
    DateTime? to,
    int limit = 500,
    int offset = 0,
  }) async {
    final d = await db;
    final where = <String>[];
    final args = <dynamic>[];
    if (from != null) {
      where.add('recorded_at >= ?');
      args.add(from.toIso8601String());
    }
    if (to != null) {
      where.add('recorded_at <= ?');
      args.add(to.toIso8601String());
    }
    final rows = await d.query(
      'health_records',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'recorded_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(HealthRecord.fromMap).toList();
  }

  Future<void> deleteOlderThan(Duration age) async {
    final d = await db;
    final cutoff = DateTime.now().subtract(age).toIso8601String();
    await d.delete('health_records',
        where: 'recorded_at < ?', whereArgs: [cutoff]);
  }
}
