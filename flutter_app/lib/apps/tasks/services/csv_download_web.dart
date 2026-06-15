// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;

/// Saves [content] as a downloadable CSV file in the browser.
Future<bool> downloadCsv(String filename, String content) async {
  final bytes = utf8.encode(content);
  final blob = html.Blob(<dynamic>[bytes], 'text/csv');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = filename
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
  return true;
}
