class ModelProfile {
  final String id;
  final String name;
  final String provider;
  final String modelId;
  final String endpoint;
  final String apiKey;
  final String apiMode;
  final String keyEnv;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastTestAt;
  final bool? lastTestSuccess;
  final String? lastTestMessage;

  const ModelProfile({
    required this.id,
    required this.name,
    required this.provider,
    required this.modelId,
    required this.endpoint,
    required this.apiKey,
    required this.apiMode,
    required this.keyEnv,
    required this.createdAt,
    required this.updatedAt,
    this.lastTestAt,
    this.lastTestSuccess,
    this.lastTestMessage,
  });

  ModelProfile copyWith({
    String? name,
    String? provider,
    String? modelId,
    String? endpoint,
    String? apiKey,
    String? apiMode,
    String? keyEnv,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastTestAt,
    bool? lastTestSuccess,
    String? lastTestMessage,
    bool clearLastTest = false,
  }) {
    return ModelProfile(
      id: id,
      name: name ?? this.name,
      provider: provider ?? this.provider,
      modelId: modelId ?? this.modelId,
      endpoint: endpoint ?? this.endpoint,
      apiKey: apiKey ?? this.apiKey,
      apiMode: apiMode ?? this.apiMode,
      keyEnv: keyEnv ?? this.keyEnv,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastTestAt: clearLastTest ? null : (lastTestAt ?? this.lastTestAt),
      lastTestSuccess: clearLastTest ? null : (lastTestSuccess ?? this.lastTestSuccess),
      lastTestMessage: clearLastTest ? null : (lastTestMessage ?? this.lastTestMessage),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'provider': provider,
      'modelId': modelId,
      'endpoint': endpoint,
      'apiKey': apiKey,
      'apiMode': apiMode,
      'keyEnv': keyEnv,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      'lastTestAt': lastTestAt?.toUtc().toIso8601String(),
      'lastTestSuccess': lastTestSuccess,
      'lastTestMessage': lastTestMessage,
    };
  }

  factory ModelProfile.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now().toUtc();
    final createdAt = DateTime.tryParse((json['createdAt'] ?? '').toString())?.toUtc() ?? now;
    final updatedAt = DateTime.tryParse((json['updatedAt'] ?? '').toString())?.toUtc() ?? createdAt;
    final lastTestAt = DateTime.tryParse((json['lastTestAt'] ?? '').toString())?.toUtc();

    return ModelProfile(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      provider: (json['provider'] ?? '').toString(),
      modelId: (json['modelId'] ?? '').toString(),
      endpoint: (json['endpoint'] ?? '').toString(),
      apiKey: (json['apiKey'] ?? '').toString(),
      apiMode: (json['apiMode'] ?? '').toString(),
      keyEnv: (json['keyEnv'] ?? '').toString(),
      createdAt: createdAt,
      updatedAt: updatedAt,
      lastTestAt: lastTestAt,
      lastTestSuccess: json['lastTestSuccess'] is bool ? json['lastTestSuccess'] as bool : null,
      lastTestMessage: json['lastTestMessage']?.toString(),
    );
  }
}

class ModelProfilesData {
  final List<ModelProfile> profiles;
  final String? selectedProfileId;

  const ModelProfilesData({
    this.profiles = const [],
    this.selectedProfileId,
  });
}
