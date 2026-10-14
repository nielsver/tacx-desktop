import 'dart:io';

/// Runs an external program; a seam so tests never spawn processes.
typedef ProcRunner =
    Future<ProcessResult> Function(String executable, List<String> args);

Future<ProcessResult> _runProcess(String exe, List<String> args) =>
    Process.run(exe, args);

/// Garmin Connect's manual import page (TCX drag & drop). No API, no login
/// handled by us.
const kGarminImportUrl = 'https://connect.garmin.com/modern/import-data';

/// "Show in folder" and "open URL" without new dependencies (step 4, R1).
///
/// * Linux: `org.freedesktop.FileManager1.ShowItems` over D-Bus (Dolphin /
///   Nautilus select the file), falling back to `xdg-open <folder>`.
/// * Windows: `explorer /select,<path>`.
/// * macOS: `open -R <path>`.
class Reveal {
  Reveal({ProcRunner? run, String? os})
    : _run = run ?? _runProcess,
      _os = os ?? Platform.operatingSystem;

  final ProcRunner _run;
  final String _os;

  /// `dbus-send` arguments for ShowItems on [absPath].
  static List<String> showItemsArgs(String absPath) => [
    '--session',
    '--print-reply',
    '--dest=org.freedesktop.FileManager1',
    '--type=method_call',
    '/org/freedesktop/FileManager1',
    'org.freedesktop.FileManager1.ShowItems',
    'array:string:${Uri.file(absPath)}',
    'string:',
  ];

  /// Folder containing [path] (no trailing separator).
  static String folderOf(String path, {bool windows = false}) {
    final sep = windows ? r'\' : '/';
    final i = path.lastIndexOf(sep);
    return i <= 0 ? (i == 0 ? sep : '.') : path.substring(0, i);
  }

  Future<bool> _ok(
    String exe,
    List<String> args, {
    bool anyExit = false,
  }) async {
    try {
      final r = await _run(exe, args);
      return anyExit || r.exitCode == 0;
    } on Object {
      return false; // not installed / not on PATH
    }
  }

  /// Opens the file manager with [path] selected (or its folder). Returns
  /// false when nothing could be opened.
  Future<bool> showInFolder(String path) async {
    switch (_os) {
      case 'linux':
        if (await _ok('dbus-send', showItemsArgs(path))) return true;
        return _ok('xdg-open', [folderOf(path)]);
      case 'windows':
        // Explorer exits 1 even on success; only a launch failure counts.
        return _ok('explorer', ['/select,$path'], anyExit: true);
      case 'macos':
        return _ok('open', ['-R', path]);
      default:
        return false;
    }
  }

  /// Opens [url] in the default browser.
  Future<bool> openUrl(String url) {
    switch (_os) {
      case 'linux':
        return _ok('xdg-open', [url]);
      case 'windows':
        // `start` treats the first quoted arg as a title: pass an empty one.
        return _ok('cmd', ['/c', 'start', '', url], anyExit: true);
      case 'macos':
        return _ok('open', [url]);
      default:
        return Future.value(false);
    }
  }
}
