/// Non-web fallback: file download isn't available, so signal the caller to use
/// an alternate path (such as copying to the clipboard).
Future<bool> downloadCsv(String filename, String content) async => false;
