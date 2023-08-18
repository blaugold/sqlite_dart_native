import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart';

const year = 2023;
const version = '3.42.0';
const sourcesPath = 'src/sqlite';

String get versionNumber {
  final versionComponents = version.split('.');
  final major = versionComponents[0];
  final minor = versionComponents[1];
  final patch = versionComponents[2];
  return '$major${minor.padLeft(2, '0')}${patch.padLeft(2, '0')}00';
}

Uri get amalgamationArchiveUrl => Uri.parse(
      'https://www.sqlite.org/$year/sqlite-amalgamation-$versionNumber.zip',
    );

void main() async {
  final temporaryDirectory = Directory.systemTemp.createTempSync();

  print('Downloading SQLite amalgamation archive...');
  final archiveFile = File('${temporaryDirectory.path}/sqlite.zip');
  final response = await get(amalgamationArchiveUrl);
  if (response.statusCode != 200) {
    throw Exception(
      'Failed to download SQLite amalgamation archive: '
      '${response.statusCode} ${response.reasonPhrase}',
    );
  }
  archiveFile.writeAsBytesSync(response.bodyBytes);

  print('Extracting SQLite amalgamation archive...');
  final unzipResult = Process.runSync(
    'unzip',
    [archiveFile.path, '-d', temporaryDirectory.path],
    stderrEncoding: utf8,
    stdoutEncoding: utf8,
  );
  if (unzipResult.exitCode != 0) {
    throw Exception(
      'Failed to extract SQLite amalgamation archive: '
      '${unzipResult.exitCode}\n${unzipResult.stdout}\n${unzipResult.stderr}',
    );
  }

  print('Copying SQLite amalgamation files...');
  Directory(sourcesPath).deleteSync(recursive: true);
  Directory(
    '${temporaryDirectory.path}/sqlite-amalgamation-$versionNumber',
  ).renameSync(sourcesPath);

  temporaryDirectory.deleteSync(recursive: true);
}
