import 'package:flutter_test/flutter_test.dart';
import 'package:multi_message_hub/models/profile_instance.dart';

void main() {
  test('ProfileInstance serialization test', () {
    final now = DateTime.now();
    final profile = ProfileInstance(
      uuid: 'profile_test123',
      customName: 'Office Phone',
      unreadCount: 3,
      createdAt: now,
      mobileMode: true,
    );

    final map = profile.toMap();
    expect(map['uuid'], 'profile_test123');
    expect(map['customName'], 'Office Phone');
    expect(map['unreadCount'], 3);

    final fromMap = ProfileInstance.fromMap(map);
    expect(fromMap.uuid, profile.uuid);
    expect(fromMap.customName, profile.customName);
    expect(fromMap.unreadCount, 3);
  });
}
