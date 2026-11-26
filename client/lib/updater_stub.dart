/// Web/no-op stub — real implementation lives in updater_io.dart and is
/// selected via conditional import in updater.dart.
class AppUpdater {
  static const supported = false;

  static Future<String?> checkForUpdate() async => null;

  static Future<void> downloadUpdate(String tag,
      {void Function(double)? onProgress}) async {
    throw UnsupportedError('Updates are only supported on desktop builds');
  }

  static Future<void> applyAndRestart() async {}
}
