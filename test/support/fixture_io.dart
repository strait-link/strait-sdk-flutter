import 'dart:io';

Future<String> readFixture(String name) async => File('test/$name').readAsString();
