// Triggers a CSV file download. On web this saves a file via the browser; on
// other platforms it returns false so the caller can fall back (e.g. copy to
// clipboard).
export 'csv_download_stub.dart'
    if (dart.library.html) 'csv_download_web.dart';
