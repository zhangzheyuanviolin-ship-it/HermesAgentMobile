import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/model_profile_models.dart';

class ModelProfileStore {
  static const String _storeFileName = 'model_profiles_v1.json';

  Future<File> _storeFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_storeFileName');
  }

  Future<ModelProfilesData> loadStore() async {
    try {
      final file = await _storeFile();
      if (!await file.exists()) {
        return const ModelProfilesData();
      }

      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const ModelProfilesData();
      }

      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) {
        return const ModelProfilesData();
      }

      final profilesRaw = data['profiles'];
      final profiles = <ModelProfile>[];
      if (profilesRaw is List) {
        for (final item in profilesRaw) {
          if (item is Map<String, dynamic>) {
            profiles.add(ModelProfile.fromJson(item));
          } else if (item is Map) {
            profiles.add(ModelProfile.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      }

      final selectedId = data['selectedProfileId']?.toString();
      return ModelProfilesData(
        profiles: profiles,
        selectedProfileId: (selectedId?.isNotEmpty == true) ? selectedId : null,
      );
    } catch (_) {
      return const ModelProfilesData();
    }
  }

  Future<void> saveStore({
    required List<ModelProfile> profiles,
    String? selectedProfileId,
  }) async {
    final file = await _storeFile();
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }

    final payload = {
      'version': 1,
      'selectedProfileId': selectedProfileId,
      'profiles': profiles.map((p) => p.toJson()).toList(),
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
  }
}
