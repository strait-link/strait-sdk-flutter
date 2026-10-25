import 'dart:convert';

import 'package:strait_sdk/strait_sdk.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

// doctor-vectors.json (contract B23, ADR 0002): the same inputs give the same
// ids, severities, titles and fixes as the React Native reference (0.9.3) and
// the Android SDK, which carry the same file.
void main() async {
  final vectors = (jsonDecode(await readFixture('doctor-vectors.json')) as Map)['vectors'] as List;

  test('has a vector for every ADR row', () => expect(vectors.length, greaterThanOrEqualTo(40)));

  for (final v in vectors.cast<Map>()) {
    test(v['name'], () {
      final input = v['input'] as Map;
      final file = input['file'] as Map?;
      final report = doctorFindings(
        publishableKey: input['publishableKey'] as String,
        endpoint: input['endpoint'] as String,
        platform: input['platform'] as String,
        appId: input['appId'] as String?,
        certSha256: (input['certSha256'] as List).cast<String>(),
        file: file == null ? null : DoctorFile(file['status'] as int?, file['body'] as String?),
      );
      expect(jsonEncode(report.toJson()), jsonEncode({'ok': v['ok'], 'findings': v['findings']}));
    });
  }
}
