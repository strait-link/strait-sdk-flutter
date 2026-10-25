import 'package:http/http.dart' as http;

Future<String> readFixture(String name) => http.read(Uri.base.resolve(name));
