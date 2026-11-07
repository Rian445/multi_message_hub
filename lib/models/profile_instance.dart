import 'dart:convert';

class ProfileInstance {
  final String uuid;
  final String customName;
  final int unreadCount;
  final DateTime createdAt;
  final bool mobileMode;

  ProfileInstance({
    required this.uuid,
    required this.customName,
    this.unreadCount = 0,
    required this.createdAt,
    this.mobileMode = true,
  });

  ProfileInstance copyWith({
    String? uuid,
    String? customName,
    int? unreadCount,
    DateTime? createdAt,
    bool? mobileMode,
  }) {
    return ProfileInstance(
      uuid: uuid ?? this.uuid,
      customName: customName ?? this.customName,
      unreadCount: unreadCount ?? this.unreadCount,
      createdAt: createdAt ?? this.createdAt,
      mobileMode: mobileMode ?? this.mobileMode,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'customName': customName,
      'unreadCount': unreadCount,
      'createdAt': createdAt.toIso8601String(),
      'mobileMode': mobileMode,
    };
  }

  factory ProfileInstance.fromMap(Map<String, dynamic> map) {
    return ProfileInstance(
      uuid: map['uuid'] as String,
      customName: map['customName'] as String,
      unreadCount: (map['unreadCount'] as num?)?.toInt() ?? 0,
      createdAt: map['createdAt'] != null
          ? DateTime.tryParse(map['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      mobileMode: map['mobileMode'] as bool? ?? true,
    );
  }

  String toJson() => json.encode(toMap());

  factory ProfileInstance.fromJson(String source) =>
      ProfileInstance.fromMap(json.decode(source) as Map<String, dynamic>);
}
