import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/task.dart';

class DatabaseService {
  static final DatabaseService instance = DatabaseService._init();
  static Database? _database;

  DatabaseService._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('tasks.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 6, 
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    const idType = 'INTEGER PRIMARY KEY AUTOINCREMENT';
    const textType = 'TEXT NOT NULL';
    const intType = 'INTEGER NOT NULL';

    await db.execute('''
      CREATE TABLE tasks (
        id $idType,
        title $textType,
        description $textType,
        priority $textType,
        completed $intType,
        createdAt $textType,
        updatedAt TEXT,
        photoPath TEXT,
        photoPaths TEXT,
        completedAt TEXT,
        completedBy TEXT,
        latitude REAL,
        longitude REAL,
        locationName TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        action TEXT NOT NULL, -- create, update, delete
        payload TEXT NOT NULL, -- JSON payload
        createdAt TEXT NOT NULL
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE tasks ADD COLUMN photoPath TEXT');
    }

    if (oldVersion < 3) {
      await db.execute('ALTER TABLE tasks ADD COLUMN completedAt TEXT');
      await db.execute('ALTER TABLE tasks ADD COLUMN completedBy TEXT');
    }

    if (oldVersion < 4) {
      await db.execute('ALTER TABLE tasks ADD COLUMN latitude REAL');
      await db.execute('ALTER TABLE tasks ADD COLUMN longitude REAL');
      await db.execute('ALTER TABLE tasks ADD COLUMN locationName TEXT');
    }

    if (oldVersion < 5) {
      await db.execute('ALTER TABLE tasks ADD COLUMN photoPaths TEXT');

      final List<Map<String, dynamic>> tasks = await db.query('tasks');
      for (final task in tasks) {
        if (task['photoPath'] != null) {
          await db.update(
            'tasks',
            {'photoPaths': jsonEncode([task['photoPath']])},
            where: 'id = ?',
            whereArgs: [task['id']],
          );
        }
      }

      debugPrint('✅ Dados de fotos migrados com sucesso!');
    }

    if (oldVersion < 6) {
      await db.execute('ALTER TABLE tasks ADD COLUMN updatedAt TEXT');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS sync_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          action TEXT NOT NULL,
          payload TEXT NOT NULL,
          createdAt TEXT NOT NULL
        )
      ''');
    }

    debugPrint('Banco migrado de v$oldVersion para v$newVersion');
  }

  // CRUD Methods
  Future<Task> create(Task task) async {
    final db = await instance.database;
    final now = DateTime.now();
    final withUpdated = task.copyWith(updatedAt: now);
    final id = await db.insert('tasks', withUpdated.toMap());
    await db.insert('sync_queue', {
      'action': 'create',
      'payload': jsonEncode(withUpdated.copyWith(id: id).toMap()),
      'createdAt': DateTime.now().toIso8601String(),
    });
    return withUpdated.copyWith(id: id);
  }

  Future<Task?> read(int id) async {
    final db = await instance.database;
    final maps = await db.query('tasks', where: 'id = ?', whereArgs: [id]);

    if (maps.isNotEmpty) {
      return Task.fromMap(maps.first);
    }
    return null;
  }

  Future<List<Task>> readAll() async {
    final db = await instance.database;
    const orderBy = 'createdAt DESC';
    final result = await db.query('tasks', orderBy: orderBy);
    return result.map((json) => Task.fromMap(json)).toList();
  }

  Future<int> update(Task task) async {
    final db = await instance.database;
    // set updatedAt
    final updated = task.copyWith(updatedAt: DateTime.now());
    final rows = await db.update(
      'tasks',
      updated.toMap(),
      where: 'id = ?',
      whereArgs: [task.id],
    );
    // enqueue sync
    await db.insert('sync_queue', {
      'action': 'update',
      'payload': jsonEncode(updated.toMap()),
      'createdAt': DateTime.now().toIso8601String(),
    });
    return rows;
  }

  Future<int> delete(int id) async {
    final db = await instance.database;
    // enqueue delete
    final toDelete = await read(id);
    if (toDelete != null) {
      await db.insert('sync_queue', {
        'action': 'delete',
        'payload': jsonEncode(toDelete.toMap()),
        'createdAt': DateTime.now().toIso8601String(),
      });
    }
    return await db.delete('tasks', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, dynamic>>> getPendingSync() async {
    final db = await instance.database;
    return await db.query('sync_queue', orderBy: 'createdAt ASC');
  }

  Future<void> removeSyncEntry(int queueId) async {
    final db = await instance.database;
    await db.delete('sync_queue', where: 'id = ?', whereArgs: [queueId]);
  }

  Future<Task?> getTaskById(int id) async {
    return await read(id);
  }

  Future<void> upsertTaskFromServer(Map<String, dynamic> serverMap) async {
    final db = await instance.database;
    final serverTask = Task.fromMap(serverMap);

    final local = await read(serverTask.id!);
    if (local == null) {
      // insert
      await db.insert('tasks', serverTask.toMap());
      return;
    }

    final localUpdated = local.updatedAt ?? local.createdAt;
    final serverUpdated = serverTask.updatedAt ?? serverTask.createdAt;
    if (serverUpdated.isAfter(localUpdated)) {
      await db.update('tasks', serverTask.toMap(), where: 'id = ?', whereArgs: [serverTask.id]);
    }
  }

  Future<bool> isTaskPending(int taskId) async {
    final db = await instance.database;
    final rows = await db.query('sync_queue');
    for (final r in rows) {
      try {
        final Map<String, dynamic> payload = jsonDecode(r['payload'] as String);
        if (payload['id'] == taskId) return true;
      } catch (_) {}
    }
    return false;
  }

  Future<List<Task>> getTasksNearLocation({
    required double latitude,
    required double longitude,
    double radiusInMeters = 1000,
  }) async {
    final allTasks = await readAll();

    return allTasks.where((task) {
      if (task.latitude == null || task.longitude == null) return false;

      final latDiff = (task.latitude! - latitude).abs();
      final lonDiff = (task.longitude! - longitude).abs();
      final distance = ((latDiff * 111000) + (lonDiff * 111000)) / 2;

      return distance <= radiusInMeters;
    }).toList();
  }

  Future close() async {
    final db = await instance.database;
    db.close();
  }
}
