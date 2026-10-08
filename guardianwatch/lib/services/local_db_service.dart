// ─── lib/services/local_db_service.dart ──────────────────────────────────────
//
// Guardian Watch local persistence layer.
//
// Responsibilities:
//   SQLite database management
//   Health-record persistence
//   Offline-first history
//   Sync-state tracking
//   ECG session metadata
//   Insight persistence
//   User-scoped queries
//   Database migrations
//
// NOTE:
// Raw high-frequency ECG samples are intentionally NOT stored in
// health_records. ECG recordings should use a dedicated storage strategy.
//
// SCHEMA VERSION HISTORY
//   1 — initial health_records table
//   2 — added device_id, session_id, battery, is_synced, created_at
//   3 — added ecg_sessions, insights, sync_queue
//

import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/health_record.dart';
import '../models/insight.dart';

class LocalDbService {
  LocalDbService._internal();

  static final LocalDbService _instance = LocalDbService._internal();

  factory LocalDbService() => _instance;

  static const String _databaseName = 'guardianwrist.db';
  static const int _databaseVersion = 3;

  static Database? _db;

  // ═════════════════════════════════════════════════════════════════════════
  // Database getter
  // ═════════════════════════════════════════════════════════════════════════

  Future<Database> get db async {
    final existing = _db;
    if (existing != null && existing.isOpen) {
      return existing;
    }

    final opened = await _open();
    _db = opened;
    return opened;
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Open
  // ═════════════════════════════════════════════════════════════════════════

  Future<Database> _open() async {
    final databasePath = join(await getDatabasesPath(), _databaseName);

    return openDatabase(
      databasePath,
      version: _databaseVersion,

      onConfigure: (database) async {
        await database.execute('PRAGMA foreign_keys = ON');
      },

      onCreate: (database, version) async {
        await _createSchema(database);
      },

      onUpgrade: (database, oldVersion, newVersion) async {
        await _migrate(database, oldVersion, newVersion);
      },
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Schema — fresh installs
  // ═════════════════════════════════════════════════════════════════════════
  //
  // The column definitions here MUST match the final state produced by
  // _migrate() so that fresh installs and upgrades produce identical schemas.

  Future<void> _createSchema(Database database) async {
    await database.transaction((transaction) async {
      // ── health_records ─────────────────────────────────────────────────

      await transaction.execute('''
        CREATE TABLE health_records (
          id            TEXT PRIMARY KEY,
          user_id       TEXT NOT NULL,
          device_id     TEXT,
          session_id    TEXT,
          heart_rate    INTEGER,
          spo2          INTEGER,
          temperature   REAL,
          battery       INTEGER,
          recorded_at   TEXT NOT NULL,
          is_synced     INTEGER NOT NULL DEFAULT 0,
          created_at    TEXT NOT NULL
        )
      ''');

      await transaction.execute(
        'CREATE INDEX idx_health_user ON health_records(user_id)',
      );

      await transaction.execute(
        'CREATE INDEX idx_health_recorded_at ON health_records(recorded_at)',
      );

      await transaction.execute(
        'CREATE INDEX idx_health_user_recorded '
        'ON health_records(user_id, recorded_at)',
      );

      await transaction.execute(
        'CREATE INDEX idx_health_sync ON health_records(is_synced)',
      );

      await transaction.execute(
        'CREATE INDEX idx_health_device ON health_records(device_id)',
      );

      // ── ecg_sessions ───────────────────────────────────────────────────

      await transaction.execute('''
        CREATE TABLE ecg_sessions (
          id              TEXT PRIMARY KEY,
          user_id         TEXT NOT NULL,
          device_id       TEXT,
          started_at      TEXT NOT NULL,
          ended_at        TEXT,
          sample_rate     INTEGER NOT NULL,
          sample_count    INTEGER NOT NULL DEFAULT 0,
          duration_ms     INTEGER,
          signal_quality  INTEGER,
          storage_path    TEXT,
          is_synced       INTEGER NOT NULL DEFAULT 0,
          created_at      TEXT NOT NULL
        )
      ''');

      await transaction.execute(
        'CREATE INDEX idx_ecg_user ON ecg_sessions(user_id)',
      );

      await transaction.execute(
        'CREATE INDEX idx_ecg_started ON ecg_sessions(started_at)',
      );

      await transaction.execute(
        'CREATE INDEX idx_ecg_user_started '
        'ON ecg_sessions(user_id, started_at)',
      );

      await transaction.execute(
        'CREATE INDEX idx_ecg_sync ON ecg_sessions(is_synced)',
      );

      // ── insights ───────────────────────────────────────────────────────

      await transaction.execute('''
        CREATE TABLE insights (
          id                TEXT PRIMARY KEY,
          user_id           TEXT,
          title             TEXT NOT NULL,
          summary           TEXT NOT NULL,
          detail            TEXT NOT NULL,
          severity          TEXT NOT NULL,
          is_premium        INTEGER NOT NULL DEFAULT 0,
          generated_at      TEXT NOT NULL,
          recommendation    TEXT,
          health_record_id  TEXT,
          algorithm_version TEXT,
          is_synced         INTEGER NOT NULL DEFAULT 0
        )
      ''');

      await transaction.execute(
        'CREATE INDEX idx_insights_user ON insights(user_id)',
      );

      await transaction.execute(
        'CREATE INDEX idx_insights_generated ON insights(generated_at)',
      );

      await transaction.execute(
        'CREATE INDEX idx_insights_sync ON insights(is_synced)',
      );

      await transaction.execute(
        'CREATE INDEX idx_insights_severity ON insights(severity)',
      );

      // ── sync_queue ─────────────────────────────────────────────────────

      await transaction.execute('''
        CREATE TABLE sync_queue (
          id                INTEGER PRIMARY KEY AUTOINCREMENT,
          record_type       TEXT NOT NULL,
          record_id         TEXT NOT NULL,
          user_id           TEXT NOT NULL,
          payload           TEXT NOT NULL,
          attempts          INTEGER NOT NULL DEFAULT 0,
          status            TEXT NOT NULL DEFAULT 'pending',
          last_attempt_at   TEXT,
          created_at        TEXT NOT NULL,
          UNIQUE(record_type, record_id)
        )
      ''');

      await transaction.execute(
        'CREATE INDEX idx_sync_status ON sync_queue(status)',
      );

      await transaction.execute(
        'CREATE INDEX idx_sync_user ON sync_queue(user_id)',
      );

      await transaction.execute(
        'CREATE INDEX idx_sync_user_status ON sync_queue(user_id, status)',
      );
    });
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Migrations
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> _migrate(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    await database.transaction((transaction) async {
      if (oldVersion < 2) {
        await _addColumnIfMissing(
          transaction,
          'health_records',
          'device_id',
          'TEXT',
        );
        await _addColumnIfMissing(
          transaction,
          'health_records',
          'session_id',
          'TEXT',
        );
        await _addColumnIfMissing(
          transaction,
          'health_records',
          'battery',
          'INTEGER',
        );
        await _addColumnIfMissing(
          transaction,
          'health_records',
          'is_synced',
          'INTEGER NOT NULL DEFAULT 0',
        );
        await _addColumnIfMissing(
          transaction,
          'health_records',
          'created_at',
          'TEXT',
        );

        await transaction.execute('''
          UPDATE health_records
          SET created_at = recorded_at
          WHERE created_at IS NULL
        ''');

        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_health_user '
          'ON health_records(user_id)',
        );
        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_health_recorded_at '
          'ON health_records(recorded_at)',
        );
        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_health_user_recorded '
          'ON health_records(user_id, recorded_at)',
        );
        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_health_sync '
          'ON health_records(is_synced)',
        );
      }

      if (oldVersion < 3) {
        await transaction.execute('''
          CREATE TABLE IF NOT EXISTS ecg_sessions (
            id              TEXT PRIMARY KEY,
            user_id         TEXT NOT NULL,
            device_id       TEXT,
            started_at      TEXT NOT NULL,
            ended_at        TEXT,
            sample_rate     INTEGER NOT NULL,
            sample_count    INTEGER NOT NULL DEFAULT 0,
            duration_ms     INTEGER,
            signal_quality  INTEGER,
            storage_path    TEXT,
            is_synced       INTEGER NOT NULL DEFAULT 0,
            created_at      TEXT NOT NULL
          )
        ''');

        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_ecg_user '
          'ON ecg_sessions(user_id)',
        );
        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_ecg_started '
          'ON ecg_sessions(started_at)',
        );
        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_ecg_user_started '
          'ON ecg_sessions(user_id, started_at)',
        );
        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_ecg_sync '
          'ON ecg_sessions(is_synced)',
        );

        await transaction.execute('''
          CREATE TABLE IF NOT EXISTS insights (
            id                TEXT PRIMARY KEY,
            user_id           TEXT,
            title             TEXT NOT NULL,
            summary           TEXT NOT NULL,
            detail            TEXT NOT NULL,
            severity          TEXT NOT NULL,
            is_premium        INTEGER NOT NULL DEFAULT 0,
            generated_at      TEXT NOT NULL,
            recommendation    TEXT,
            health_record_id  TEXT,
            algorithm_version TEXT,
            is_synced         INTEGER NOT NULL DEFAULT 0
          )
        ''');

        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_insights_user '
          'ON insights(user_id)',
        );
        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_insights_generated '
          'ON insights(generated_at)',
        );
        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_insights_sync '
          'ON insights(is_synced)',
        );
        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_insights_severity '
          'ON insights(severity)',
        );

        await transaction.execute('''
          CREATE TABLE IF NOT EXISTS sync_queue (
            id                INTEGER PRIMARY KEY AUTOINCREMENT,
            record_type       TEXT NOT NULL,
            record_id         TEXT NOT NULL,
            user_id           TEXT NOT NULL,
            payload           TEXT NOT NULL,
            attempts          INTEGER NOT NULL DEFAULT 0,
            status            TEXT NOT NULL DEFAULT 'pending',
            last_attempt_at   TEXT,
            created_at        TEXT NOT NULL,
            UNIQUE(record_type, record_id)
          )
        ''');

        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_sync_status '
          'ON sync_queue(status)',
        );
        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_sync_user '
          'ON sync_queue(user_id)',
        );
        await transaction.execute(
          'CREATE INDEX IF NOT EXISTS idx_sync_user_status '
          'ON sync_queue(user_id, status)',
        );
      }
    });
  }

  Future<void> _addColumnIfMissing(
    DatabaseExecutor database,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await database.rawQuery('PRAGMA table_info($table)');
    final exists = columns.any((info) => info['name'] == column);

    if (!exists) {
      await database.execute(
        'ALTER TABLE $table ADD COLUMN $column $definition',
      );
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Health Records
  // ═════════════════════════════════════════════════════════════════════════

  /// Inserts a health record and, optionally, queues it for sync — atomically.
  ///
  /// [created_at] is preserved if the record already carries one; otherwise
  /// the current UTC time is written.
  ///
  /// When [enqueueForSync] is true, the record and its sync-queue entry are
  /// written in a single transaction so a crash cannot leave a record
  /// stranded with no pending upload.
  Future<void> insertRecord(
    HealthRecord record, {
    bool enqueueForSync = true,
  }) async {
    final database = await db;
    final data = record.toMap();

    // Do not clobber an existing created_at (e.g. re-inserted records).
    data.putIfAbsent(
      'created_at',
      () => DateTime.now().toUtc().toIso8601String(),
    );

    await database.transaction((txn) async {
      await txn.insert(
        'health_records',
        data,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      if (enqueueForSync) {
        final userId = data['user_id'] as String?;
        if (userId == null || userId.isEmpty) {
          // Refuse to orphan a sync entry — caller must scope records
          // to a user.
          return;
        }

        await txn.insert(
          'sync_queue',
          {
            'record_type': 'health_record',
            'record_id': record.id,
            'user_id': userId,
            'payload': jsonEncode(data),
            'attempts': 0,
            'status': 'pending',
            'created_at': DateTime.now().toUtc().toIso8601String(),
          },
          // Replace so an updated payload wins.
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<List<HealthRecord>> queryRecords({
    String? userId,
    DateTime? from,
    DateTime? to,
    int limit = 500,
    int offset = 0,
  }) async {
    final database = await db;

    final where = <String>[];
    final args = <dynamic>[];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    if (from != null) {
      where.add('recorded_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }

    if (to != null) {
      where.add('recorded_at <= ?');
      args.add(to.toUtc().toIso8601String());
    }

    final rows = await database.query(
      'health_records',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'recorded_at DESC',
      limit: limit,
      offset: offset,
    );

    return rows.map(HealthRecord.fromMap).toList();
  }

  Future<HealthRecord?> getRecordById(String id, {String? userId}) async {
    final database = await db;

    final where = <String>['id = ?'];
    final args = <dynamic>[id];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    final rows = await database.query(
      'health_records',
      where: where.join(' AND '),
      whereArgs: args,
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return HealthRecord.fromMap(rows.first);
  }

  Future<int> markRecordSynced(String id, {String? userId}) async {
    final database = await db;

    final where = <String>['id = ?'];
    final args = <dynamic>[id];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    return database.update(
      'health_records',
      {'is_synced': 1},
      where: where.join(' AND '),
      whereArgs: args,
    );
  }

  Future<List<HealthRecord>> getUnsyncedRecords({
    String? userId,
    int limit = 100,
  }) async {
    final database = await db;

    final where = <String>['is_synced = 0'];
    final args = <dynamic>[];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    final rows = await database.query(
      'health_records',
      where: where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'recorded_at ASC',
      limit: limit,
    );

    return rows.map(HealthRecord.fromMap).toList();
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Health Record — delete / retention
  // ═════════════════════════════════════════════════════════════════════════

  Future<int> deleteOlderThan(Duration age, {String? userId}) async {
    final database = await db;

    final cutoff = DateTime.now().subtract(age).toUtc().toIso8601String();

    final where = <String>['recorded_at < ?'];
    final args = <dynamic>[cutoff];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    return database.delete(
      'health_records',
      where: where.join(' AND '),
      whereArgs: args,
    );
  }

  Future<int> deleteRecord(String id, {String? userId}) async {
    final database = await db;

    final where = <String>['id = ?'];
    final args = <dynamic>[id];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    return database.delete(
      'health_records',
      where: where.join(' AND '),
      whereArgs: args,
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  // ECG session metadata
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> createEcgSession({
    required String id,
    required String userId,
    String? deviceId,
    required int sampleRate,
    String? storagePath,
  }) async {
    final database = await db;
    final now = DateTime.now().toUtc().toIso8601String();

    await database.insert('ecg_sessions', {
      'id': id,
      'user_id': userId,
      'device_id': deviceId,
      'started_at': now,
      'sample_rate': sampleRate,
      'sample_count': 0,
      'storage_path': storagePath,
      'is_synced': 0,
      'created_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> updateEcgSession({
    required String id,
    String? userId,
    DateTime? endedAt,
    int? sampleCount,
    int? durationMs,
    int? signalQuality,
    String? storagePath,
    bool? isSynced,
  }) async {
    final database = await db;

    final updates = <String, dynamic>{};

    if (endedAt != null) {
      updates['ended_at'] = endedAt.toUtc().toIso8601String();
    }
    if (sampleCount != null) updates['sample_count'] = sampleCount;
    if (durationMs != null) updates['duration_ms'] = durationMs;
    if (signalQuality != null) updates['signal_quality'] = signalQuality;
    if (storagePath != null) updates['storage_path'] = storagePath;
    if (isSynced != null) updates['is_synced'] = isSynced ? 1 : 0;

    if (updates.isEmpty) return 0;

    final where = <String>['id = ?'];
    final args = <dynamic>[id];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    return database.update(
      'ecg_sessions',
      updates,
      where: where.join(' AND '),
      whereArgs: args,
    );
  }

  Future<Map<String, dynamic>?> getEcgSessionById(
    String id, {
    String? userId,
  }) async {
    final database = await db;

    final where = <String>['id = ?'];
    final args = <dynamic>[id];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    final rows = await database.query(
      'ecg_sessions',
      where: where.join(' AND '),
      whereArgs: args,
      limit: 1,
    );

    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> queryEcgSessions({
    String? userId,
    DateTime? from,
    DateTime? to,
    int limit = 100,
    int offset = 0,
  }) async {
    final database = await db;

    final where = <String>[];
    final args = <dynamic>[];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    if (from != null) {
      where.add('started_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }

    if (to != null) {
      where.add('started_at <= ?');
      args.add(to.toUtc().toIso8601String());
    }

    return database.query(
      'ecg_sessions',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'started_at DESC',
      limit: limit,
      offset: offset,
    );
  }

  Future<List<Map<String, dynamic>>> getUnsyncedEcgSessions({
    String? userId,
    int limit = 50,
  }) async {
    final database = await db;

    final where = <String>['is_synced = 0'];
    final args = <dynamic>[];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    return database.query(
      'ecg_sessions',
      where: where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'started_at ASC',
      limit: limit,
    );
  }

  Future<int> deleteEcgSession(String id, {String? userId}) async {
    final database = await db;

    final where = <String>['id = ?'];
    final args = <dynamic>[id];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    return database.delete(
      'ecg_sessions',
      where: where.join(' AND '),
      whereArgs: args,
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Insights
  // ═════════════════════════════════════════════════════════════════════════

  Future<void> insertInsight(
    Insight insight, {
    String? userId,
    bool isSynced = false,
  }) async {
    final database = await db;

    final map = insight.toMap();
    map['user_id'] = userId;
    map['is_synced'] = isSynced ? 1 : 0;

    await database.insert(
      'insights',
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Insight>> queryInsights({
    String? userId,
    DateTime? from,
    DateTime? to,
    int limit = 100,
    int offset = 0,
  }) async {
    final database = await db;

    final where = <String>[];
    final args = <dynamic>[];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    if (from != null) {
      where.add('generated_at >= ?');
      args.add(from.toUtc().toIso8601String());
    }

    if (to != null) {
      where.add('generated_at <= ?');
      args.add(to.toUtc().toIso8601String());
    }

    final rows = await database.query(
      'insights',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'generated_at DESC',
      limit: limit,
      offset: offset,
    );

    return rows.map(Insight.fromMap).toList();
  }

  Future<List<Insight>> getUnsyncedInsights({
    String? userId,
    int limit = 100,
  }) async {
    final database = await db;

    final where = <String>['is_synced = 0'];
    final args = <dynamic>[];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    final rows = await database.query(
      'insights',
      where: where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'generated_at ASC',
      limit: limit,
    );

    return rows.map(Insight.fromMap).toList();
  }

  Future<int> markInsightSynced(String id, {String? userId}) async {
    final database = await db;

    final where = <String>['id = ?'];
    final args = <dynamic>[id];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    return database.update(
      'insights',
      {'is_synced': 1},
      where: where.join(' AND '),
      whereArgs: args,
    );
  }

  Future<int> deleteInsight(String id, {String? userId}) async {
    final database = await db;

    final where = <String>['id = ?'];
    final args = <dynamic>[id];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    return database.delete(
      'insights',
      where: where.join(' AND '),
      whereArgs: args,
    );
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Sync queue
  // ═════════════════════════════════════════════════════════════════════════

  /// Enqueues a sync item.
  ///
  /// `userId` is required so that per-user filters never orphan items.
  /// A duplicate (record_type, record_id) replaces the existing entry so
  /// an updated payload wins.
  Future<void> enqueueSync({
    required String recordType,
    required String recordId,
    required String userId,
    required Map<String, dynamic> payload,
  }) async {
    if (userId.isEmpty) {
      throw ArgumentError.value(
        userId,
        'userId',
        'enqueueSync requires a non-empty userId.',
      );
    }

    final database = await db;

    await database.insert('sync_queue', {
      'record_type': recordType,
      'record_id': recordId,
      'user_id': userId,
      'payload': jsonEncode(payload),
      'attempts': 0,
      'status': 'pending',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Items ready for upload: pending only.
  Future<List<Map<String, dynamic>>> getPendingSyncItems({
    String? userId,
    int limit = 100,
  }) async {
    return _querySyncItems(status: 'pending', userId: userId, limit: limit);
  }

  /// Items that failed their attempt limit and can be inspected or retried.
  Future<List<Map<String, dynamic>>> getFailedSyncItems({
    String? userId,
    int limit = 100,
  }) async {
    return _querySyncItems(status: 'failed', userId: userId, limit: limit);
  }

  Future<List<Map<String, dynamic>>> _querySyncItems({
    required String status,
    String? userId,
    required int limit,
  }) async {
    final database = await db;

    final where = <String>['status = ?'];
    final args = <dynamic>[status];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    return database.query(
      'sync_queue',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'created_at ASC',
      limit: limit,
    );
  }

  /// Increments the attempt counter without changing status.
  ///
  /// Caller decides whether the item stays pending, becomes failed, or
  /// completes — via [markSyncComplete] or [markSyncFailed].
  Future<int> markSyncAttempt(int id) async {
    final database = await db;

    return database.rawUpdate(
      '''
      UPDATE sync_queue
      SET attempts = attempts + 1,
          last_attempt_at = ?
      WHERE id = ?
      ''',
      [DateTime.now().toUtc().toIso8601String(), id],
    );
  }

  Future<int> markSyncComplete(int id) async {
    final database = await db;
    return database.delete('sync_queue', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> markSyncFailed(int id) async {
    final database = await db;

    return database.update(
      'sync_queue',
      {
        'status': 'failed',
        'last_attempt_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Resets a failed item back to pending so the sync engine picks it up.
  ///
  /// Used after a transient outage or when the user taps "Retry".
  Future<int> retrySyncItem(int id) async {
    final database = await db;

    return database.update(
      'sync_queue',
      {'status': 'pending'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> getPendingSyncCount({String? userId}) async {
    final database = await db;

    final where = <String>["status = 'pending'"];
    final args = <dynamic>[];

    if (userId != null && userId.isNotEmpty) {
      where.add('user_id = ?');
      args.add(userId);
    }

    final result = await database.rawQuery(
      'SELECT COUNT(*) AS count FROM sync_queue '
      'WHERE ${where.join(' AND ')}',
      args,
    );

    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ═════════════════════════════════════════════════════════════════════════
  // Utility
  // ═════════════════════════════════════════════════════════════════════════

  /// Deletes all local data for a user across every table.
  Future<void> clearUserData(String userId) async {
    final database = await db;

    await database.transaction((transaction) async {
      await transaction.delete(
        'health_records',
        where: 'user_id = ?',
        whereArgs: [userId],
      );
      await transaction.delete(
        'ecg_sessions',
        where: 'user_id = ?',
        whereArgs: [userId],
      );
      await transaction.delete(
        'insights',
        where: 'user_id = ?',
        whereArgs: [userId],
      );
      await transaction.delete(
        'sync_queue',
        where: 'user_id = ?',
        whereArgs: [userId],
      );
    });
  }

  /// Applies the configured retention window to health records.
  ///
  /// Call from a periodic maintenance task, not on every app start.
  Future<int> applyRetentionPolicy(Duration age, {String? userId}) async {
    return deleteOlderThan(age, userId: userId);
  }

  /// Reclaims free pages. Run occasionally on long-lived installs.
  Future<void> vacuum() async {
    final database = await db;
    await database.execute('VACUUM');
  }

  Future<void> close() async {
    final existing = _db;
    if (existing != null && existing.isOpen) {
      await existing.close();
    }
    _db = null;
  }
}
