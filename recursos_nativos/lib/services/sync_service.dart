import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'database_service.dart';
import 'connectivity_service.dart';

class SyncService {
  static final SyncService instance = SyncService._init();
  SyncService._init() {
    _init();
  }

  final ValueNotifier<bool> isSyncing = ValueNotifier<bool>(false);
  VoidCallback? _connListener;
  // Use 10.0.2.2 for Android emulator to reach host machine
  // For real device, replace with your computer's IP (e.g., 'http://192.168.1.100:3001')
  final String? serverBaseUrl = 'http://10.0.2.2:3001';

  final Map<int, Map<String, dynamic>> _simulatedServerStore = {};

  void simulateServerEdit(Map<String, dynamic> serverMap) {
    try {
      final int? id = serverMap['id'] as int?;
      if (id == null) return;
      _simulatedServerStore[id] = Map<String, dynamic>.from(serverMap);
      debugPrint('🔁 Simulated server edit stored for id=$id');
    } catch (e) {
      debugPrint('Error storing simulated server edit: $e');
    }
  }

  Map<String, dynamic>? getSimulatedServerEntry(int id) {
    return _simulatedServerStore[id];
  }

  void _init() {
    _connListener = () {
      if (ConnectivityService.instance.isOnline.value) {
        _onOnline();
      }
    };
    ConnectivityService.instance.isOnline.addListener(_connListener!);

    if (ConnectivityService.instance.isOnline.value) _onOnline();
  }

  Future<void> _onOnline() async {
    await _pullServerChangesToLocal();
    await _processQueue();
  }
  
  void processPending({bool force = false}) {
    if (!force && !ConnectivityService.instance.isOnline.value) return;
    _processQueue();
  }

  Future<void> _pullServerChangesToLocal() async {
    if (serverBaseUrl == null) {
      int count = 0;
      for (final entry in _simulatedServerStore.entries) {
        final serverObj = entry.value;
        try {
          final local = await DatabaseService.instance.getTaskById(entry.key);
          final serverUpdated = serverObj['updatedAt'] != null
              ? DateTime.parse(serverObj['updatedAt'] as String)
              : DateTime.parse(serverObj['createdAt'] as String);
          if (local == null) {
            debugPrint('Sync pull: inserting server task ${entry.key} (serverUpdated=$serverUpdated)');
            await DatabaseService.instance.upsertTaskFromServer(serverObj);
          } else {
            final localUpdated = local.updatedAt ?? local.createdAt;
            if (serverUpdated.isAfter(localUpdated)) {
              debugPrint('Sync pull: server wins for id=${entry.key} (serverUpdated=$serverUpdated > localUpdated=$localUpdated). Overwriting local.');
              await DatabaseService.instance.upsertTaskFromServer(serverObj);
            } else {
              debugPrint('Sync pull: local wins for id=${entry.key} (localUpdated=$localUpdated >= serverUpdated=$serverUpdated). Keeping local.');
            }
          }
        } catch (e) {
          debugPrint('Error reconciling simulated server entry ${entry.key}: $e');
        }
        count++;
        if (count % 5 == 0) await Future.delayed(const Duration(milliseconds: 50));
      }
    } else {
    }
  }

  Future<void> _processQueue() async {
    if (isSyncing.value) return;
    isSyncing.value = true;

    final db = await DatabaseService.instance.database;
    try {
      const int batchSize = 10;
      const int maxItemsPerInvocation = 50;
      int processedCount = 0;
      outerLoop:
      while (true) {
        final rows = await db.query('sync_queue', orderBy: 'createdAt ASC', limit: batchSize);
        if (rows.isEmpty) break;

        for (final row in rows) {
          final int rowId = row['id'] as int;
          final String action = row['action'] as String;
          final String payload = row['payload'] as String;

          try {
            final payloadMap = jsonDecode(payload) as Map<String, dynamic>;

            if (serverBaseUrl == null) {
              final int? taskId = payloadMap['id'] as int?;
              if (action == 'create') {
                final int assignedId = taskId ?? DateTime.now().millisecondsSinceEpoch;
                final serverObj = Map<String, dynamic>.from(payloadMap);
                serverObj['id'] = assignedId;
                _simulatedServerStore[assignedId] = serverObj;
                await db.delete('sync_queue', where: 'id = ?', whereArgs: [rowId]);
                continue;
              }

              if (action == 'update') {
                if (taskId == null) {
                  await db.delete('sync_queue', where: 'id = ?', whereArgs: [rowId]);
                  continue;
                }

                final serverObj = _simulatedServerStore[taskId];
                final serverUpdated = serverObj != null && serverObj['updatedAt'] != null
                    ? DateTime.parse(serverObj['updatedAt'] as String)
                    : null;
                final localUpdated = payloadMap['updatedAt'] != null
                    ? DateTime.parse(payloadMap['updatedAt'] as String)
                    : DateTime.parse(payloadMap['createdAt'] as String);

                if (serverObj != null && serverUpdated != null && serverUpdated.isAfter(localUpdated)) {
                  debugPrint('Sync push: server wins for id=$taskId (serverUpdated=$serverUpdated > localUpdated=$localUpdated). Applying server and removing queue.');
                  await DatabaseService.instance.upsertTaskFromServer(serverObj);
                  await db.delete('sync_queue', where: 'id = ?', whereArgs: [rowId]);
                  continue;
                } else {
                  debugPrint('Sync push: local wins for id=$taskId (localUpdated=$localUpdated >= serverUpdated=$serverUpdated). Updating simulated server and removing queue.');
                  final newServerObj = Map<String, dynamic>.from(payloadMap);
                  _simulatedServerStore[taskId] = newServerObj;
                  await db.delete('sync_queue', where: 'id = ?', whereArgs: [rowId]);
                  continue;
                }
              }

              if (action == 'delete') {
                if (taskId != null) _simulatedServerStore.remove(taskId);
                await db.delete('sync_queue', where: 'id = ?', whereArgs: [rowId]);
                continue;
              }

              await db.delete('sync_queue', where: 'id = ?', whereArgs: [rowId]);
              continue;
            }

            if (action == 'create') {
              // If photo exists, upload it first to backend (S3 via LocalStack)
              try {
                final List<dynamic>? photoPaths = payloadMap['photoPaths'] != null
                    ? (jsonDecode(payloadMap['photoPaths'] as String) as List<dynamic>)
                    : null;
                final String? firstPhoto = (photoPaths != null && photoPaths.isNotEmpty)
                    ? (photoPaths.first as String)
                    : null;
                if (firstPhoto != null) {
                  final file = File(firstPhoto);
                  if (await file.exists()) {
                    final request = http.MultipartRequest('POST', Uri.parse('$serverBaseUrl/upload'));
                    request.fields['title'] = payloadMap['title']?.toString() ?? 'Untitled';
                    request.files.add(await http.MultipartFile.fromPath('file', firstPhoto));
                    final streamed = await request.send();
                    final uploadRes = await http.Response.fromStream(streamed);
                    if (uploadRes.statusCode >= 200 && uploadRes.statusCode < 300) {
                      final uploadBody = jsonDecode(uploadRes.body) as Map<String, dynamic>;
                      payloadMap['imageKey'] = uploadBody['key'];
                    } else {
                      debugPrint('Image upload failed: ${uploadRes.statusCode}');
                    }
                  } else {
                    debugPrint('Skipping upload; file missing at $firstPhoto');
                  }
                }
              } catch (e) {
                debugPrint('Error uploading image: $e');
              }

              // Send task payload to backend (optional stub endpoint)
              final res = await http.post(
                Uri.parse('$serverBaseUrl/tasks'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode(payloadMap),
              );
              if (res.statusCode >= 200 && res.statusCode < 300) {
                try {
                  final serverObj = jsonDecode(res.body) as Map<String, dynamic>;
                  debugPrint('Sync push (server-backed): create succeeded for server id=${serverObj['id']}');
                  await DatabaseService.instance.upsertTaskFromServer(serverObj);
                } catch (_) {}
                await db.delete('sync_queue', where: 'id = ?', whereArgs: [rowId]);
              } else {
                throw Exception('Server create failed: ${res.statusCode}');
              }
            } else if (action == 'update') {
              final int? taskId = payloadMap['id'] as int?;
              if (taskId == null) throw Exception('Missing id for update');

              final getRes = await http.get(Uri.parse('$serverBaseUrl/tasks/$taskId'));
              if (getRes.statusCode == 200) {
                final serverObj = jsonDecode(getRes.body) as Map<String, dynamic>;
                final serverUpdated = serverObj['updatedAt'] != null
                    ? DateTime.parse(serverObj['updatedAt'] as String)
                    : DateTime.parse(serverObj['createdAt'] as String);
                final localUpdated = payloadMap['updatedAt'] != null
                    ? DateTime.parse(payloadMap['updatedAt'] as String)
                    : DateTime.parse(payloadMap['createdAt'] as String);

                if (serverUpdated.isAfter(localUpdated)) {
                  debugPrint('Sync push (server-backed): server wins for id=$taskId (serverUpdated=$serverUpdated > localUpdated=$localUpdated). Applying server.');
                  await DatabaseService.instance.upsertTaskFromServer(serverObj);
                  await db.delete('sync_queue', where: 'id = ?', whereArgs: [rowId]);
                } else {
                  final putRes = await http.put(
                    Uri.parse('$serverBaseUrl/tasks/$taskId'),
                    headers: {'Content-Type': 'application/json'},
                    body: jsonEncode(payloadMap),
                  );
                  if (putRes.statusCode >= 200 && putRes.statusCode < 300) {
                    await db.delete('sync_queue', where: 'id = ?', whereArgs: [rowId]);
                  } else {
                    throw Exception('Server update failed: ${putRes.statusCode}');
                  }
                }
              } else if (getRes.statusCode == 404) {
                final res2 = await http.post(
                  Uri.parse('$serverBaseUrl/tasks'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode(payloadMap),
                );
                if (res2.statusCode >= 200 && res2.statusCode < 300) {
                  await db.delete('sync_queue', where: 'id = ?', whereArgs: [rowId]);
                } else {
                  throw Exception('Server create fallback failed: ${res2.statusCode}');
                }
              } else {
                throw Exception('Failed to fetch server task: ${getRes.statusCode}');
              }
            } else if (action == 'delete') {
              final taskId = payloadMap['id'];
              if (taskId == null) {
                await db.delete('sync_queue', where: 'id = ?', whereArgs: [rowId]);
                continue;
              }

              final delRes = await http.delete(Uri.parse('$serverBaseUrl/tasks/$taskId'));
              if (delRes.statusCode == 200 || delRes.statusCode == 204 || delRes.statusCode == 404) {
                await db.delete('sync_queue', where: 'id = ?', whereArgs: [rowId]);
              } else {
                throw Exception('Server delete failed: ${delRes.statusCode}');
              }
            } else {
              await db.delete('sync_queue', where: 'id = ?', whereArgs: [rowId]);
            }
          } catch (e) {
            debugPrint('Sync error for queue id $rowId: $e');
            break outerLoop;
          }

          await Future.delayed(const Duration(milliseconds: 10));

          processedCount++;
          if (processedCount >= maxItemsPerInvocation) {
            debugPrint('Sync: reached maxItemsPerInvocation ($processedCount). Scheduling next run.');
            break outerLoop;
          }
        }

        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (processedCount >= maxItemsPerInvocation) {
        isSyncing.value = false;
        Future.delayed(const Duration(milliseconds: 500), () {
          _processQueue();
        });
        return;
      }
    } catch (e) {
      debugPrint('Error processing sync queue: $e');
    } finally {
      isSyncing.value = false;
    }
  }

  void dispose() {
    if (_connListener != null) {
      ConnectivityService.instance.isOnline.removeListener(_connListener!);
    }
  }
}
