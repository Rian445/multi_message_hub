import 'dart:convert';

class ProfileInstance {
  final String uuid;
  final String customName;
  final int unreadCount;
  final DateTime createdAt;
  final bool mobileMode;
  final bool isHidden;
  final bool isDefault;

  ProfileInstance({
    required this.uuid,
    required this.customName,
    this.unreadCount = 0,
    required this.createdAt,
    this.mobileMode = true,
    this.isHidden = false,
    this.isDefault = false,
  });

  ProfileInstance copyWith({
    String? uuid,
    String? customName,
    int? unreadCount,
    DateTime? createdAt,
    bool? mobileMode,
    bool? isHidden,
    bool? isDefault,
  }) {
    return ProfileInstance(
      uuid: uuid ?? this.uuid,
      customName: customName ?? this.customName,
      unreadCount: unreadCount ?? this.unreadCount,
      createdAt: createdAt ?? this.createdAt,
      mobileMode: mobileMode ?? this.mobileMode,
      isHidden: isHidden ?? this.isHidden,
      isDefault: isDefault ?? this.isDefault,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'customName': customName,
      'unreadCount': unreadCount,
      'createdAt': createdAt.toIso8601String(),
      'mobileMode': mobileMode,
      'isHidden': isHidden,
      'isDefault': isDefault,
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
      isHidden: map['isHidden'] as bool? ?? false,
      isDefault: map['isDefault'] as bool? ?? false,
    );
  }

  String toJson() => json.encode(toMap());

  factory ProfileInstance.fromJson(String source) =>
      ProfileInstance.fromMap(json.decode(source) as Map<String, dynamic>);
}
