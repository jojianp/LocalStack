import 'dart:io';
import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../screens/camera_screen.dart';

Future<String> _copyFileIsolate(Map<String, String> args) async {
  final src = args['src']!;
  final dest = args['dest']!;
  final saved = await File(src).copy(dest);
  return saved.path;
}

class CameraService {
  static final CameraService instance = CameraService._init();
  CameraService._init();

  List<CameraDescription>? _cameras;

  /// Inicializa câmera em mobile; desktop ignora
  Future<void> initialize() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      debugPrint(
        '⚠️ Câmera não suportada nesta plataforma (${Platform.operatingSystem}).',
      );
      _cameras = [];
      return;
    }

    try {
      _cameras = await availableCameras();
      debugPrint(
        'CameraService: ${_cameras?.length ?? 0} câmera(s) encontrada(s)',
      );
    } catch (e) {
      debugPrint('⚠️ Erro ao inicializar câmera: $e');
      _cameras = [];
    }
  }

  bool get hasCameras => _cameras != null && _cameras!.isNotEmpty;

  /// Seleciona ou tira fotos (múltiplas se desktop)
  Future<List<String>?> pickOrTakePictures(
    BuildContext context, {
    bool multiple = false,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      // Mobile: apenas tirar uma foto
      if (!hasCameras) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Nenhuma câmera disponível'),
            backgroundColor: Colors.red,
          ),
        );
        return null;
      }

      final camera = _cameras!.first;
      final controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      bool transferred = false;
      try {
        await controller.initialize();
        if (!context.mounted) {
          await controller.dispose();
          return null;
        }

        transferred = true;
        final imagePath = await Navigator.push<String>(
          context,
          MaterialPageRoute(
            builder: (context) => CameraScreen(controller: controller),
            fullscreenDialog: true,
          ),
        );

        if (imagePath != null) return [imagePath];
        return null;
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Erro ao abrir câmera: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return null;
      } finally {
        if (!transferred) {
          try {
            await controller.dispose();
          } catch (e) {
            // ignore dispose errors
          }
        }
      }
    } else {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: multiple,
      );

      if (result != null && result.files.isNotEmpty) {
        List<String> savedPaths = [];
        final appDir = await getApplicationDocumentsDirectory();
        final imageDir = Directory(path.join(appDir.path, 'images'));
        if (!await imageDir.exists()) await imageDir.create(recursive: true);

        for (var file in result.files) {
          if (file.path == null) continue;
          final fileName = 'task_${DateTime.now().millisecondsSinceEpoch}${path.extension(file.path!)}';
          final savePath = path.join(imageDir.path, fileName);
          try {
            final saved = await compute(_copyFileIsolate, {'src': file.path!, 'dest': savePath});
            savedPaths.add(saved);
          } catch (e) {
            debugPrint('Erro ao copiar arquivo em isolate: $e');
          }
        }
        return savedPaths;
      } else {
        if (!context.mounted) return null;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Nenhuma imagem selecionada'),
            backgroundColor: Colors.red,
          ),
        );
        return null;
      }
    }
  }

  /// Salvar foto em qualquer plataforma (mobile ou desktop)
  Future<String> savePictureFile(File imageFile) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final imageDir = Directory(path.join(appDir.path, 'images'));
      if (!await imageDir.exists()) await imageDir.create(recursive: true);

      final fileName =
          'task_${DateTime.now().millisecondsSinceEpoch}${path.extension(imageFile.path)}';
      final savePath = path.join(imageDir.path, fileName);

      try {
        final savedPath = await compute(_copyFileIsolate, {'src': imageFile.path, 'dest': savePath});
        debugPrint('Foto salva: $savedPath');
        return savedPath;
      } catch (e) {
        final savedImage = await imageFile.copy(savePath);
        debugPrint('Foto salva (sync fallback): ${savedImage.path}');
        return savedImage.path;
      }
    } catch (e) {
      debugPrint('Erro ao salvar foto: $e');
      rethrow;
    }
  }

  /// Mantém método original para salvar XFile (de câmera)
  Future<String> savePicture(XFile image) async {
    return savePictureFile(File(image.path));
  }

  /// Deletar foto
  Future<bool> deletePhoto(String photoPath) async {
    try {
      final file = File(photoPath);
      if (await file.exists()) await file.delete();
      debugPrint('🗑️ Foto deletada: $photoPath');
      return true;
    } catch (e) {
      debugPrint('❌ Erro ao deletar foto: $e');
      return false;
    }
  }
}
