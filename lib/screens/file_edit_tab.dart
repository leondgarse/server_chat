import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/app_state.dart';
import '../utils/theme.dart';
import '../widgets/remote_path_picker.dart';
import '../widgets/connection_button.dart';
import '../widgets/theme_switch_button.dart';

class FileEditTab extends StatefulWidget {
  const FileEditTab({super.key});

  @override
  State<FileEditTab> createState() => _FileEditTabState();
}

class _FileEditTabState extends State<FileEditTab> {
  final TextEditingController _pathController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  bool _isLoading = false;
  bool _isSaving = false;
  String _lastKnownPath = '';

  @override
  void initState() {
    super.initState();
    _contentController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pathController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _loadFile() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not connected to SSH.')));
      return;
    }

    final path = _pathController.text.trim();
    if (path.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final content = await state.sshService.readFile(path);
      _contentController.text = content;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Loaded $path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error loading file: $e')));
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveFile() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not connected')));
      return;
    }

    final path = _pathController.text.trim();
    if (path.isEmpty) return;

    setState(() => _isSaving = true);

    try {
      await state.sshService.writeFile(path, _contentController.text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to $path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error saving: $e')));
      }
    } finally {
      setState(() => _isSaving = false);
    }
  }

  void _syncCurrentPath(AppState state) {
    if (!state.isConnected) return;
    if (state.currentPath == _lastKnownPath) return;
    _lastKnownPath = state.currentPath;
    if (_contentController.text.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pathController.text = state.currentPath;
      });
    }
  }

  // ───────── Upload ─────────

  void _showUploadSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text('Upload File'),
              onTap: () { Navigator.pop(ctx); _uploadFile(); },
            ),
            ListTile(
              leading: const Icon(Icons.folder_zip),
              title: const Text('Upload Folder'),
              onTap: () { Navigator.pop(ctx); _uploadFolder(); },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _uploadFile() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not connected')));
      return;
    }

    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty || !mounted) return;

    final localPath = result.files.first.path;
    if (localPath == null) return;

    final fileName = result.files.first.name;
    final remoteDir = state.currentPath.isNotEmpty ? state.currentPath : state.sshService.homeDir;
    final remotePath = '$remoteDir/$fileName';

    await _runFileTransfer(
      label: 'Uploading $fileName',
      transfer: (onProgress) =>
          state.sshService.uploadFile(localPath, remotePath, onProgress: onProgress),
      successMsg: 'Uploaded to $remotePath',
    );
  }

  Future<void> _uploadFolder() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not connected')));
      return;
    }

    final dirPath = await FilePicker.platform.getDirectoryPath();
    if (dirPath == null || !mounted) return;

    final dirName = dirPath.split('/').last;
    final remoteDir = state.currentPath.isNotEmpty ? state.currentPath : state.sshService.homeDir;

    await _runFolderTransfer(
      label: 'Uploading $dirName/',
      transfer: (onFile) =>
          state.sshService.uploadDirectory(dirPath, remoteDir, onProgress: onFile),
      successMsg: 'Uploaded $dirName/ to $remoteDir',
    );
  }

  // ───────── Download ─────────

  Future<void> _showDownloadPicker() async {
    final state = Provider.of<AppState>(context, listen: false);
    if (!state.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not connected')));
      return;
    }

    final remotePath = await showDialog<String>(
      context: context,
      builder: (c) => RemotePathPickerDialog(
        initialPath: _pathController.text.isNotEmpty ? _pathController.text : '~',
        foldersOnly: false,
        showSelectDir: true,
      ),
    );
    if (remotePath == null || !mounted) return;

    final docsDir = await getApplicationDocumentsDirectory();
    final isDir = await state.sshService.isRemoteDirectory(remotePath);
    if (!mounted) return;

    final name = remotePath.split('/').last;

    if (isDir) {
      await _runFolderTransfer(
        label: 'Downloading $name/',
        transfer: (onFile) =>
            state.sshService.downloadDirectory(remotePath, docsDir.path, onProgress: onFile),
        successMsg: 'Saved to ${docsDir.path}/$name',
      );
    } else {
      final localPath = '${docsDir.path}/$name';
      await _runFileTransfer(
        label: 'Downloading $name',
        transfer: (onProgress) =>
            state.sshService.downloadFile(remotePath, localPath, onProgress: onProgress),
        successMsg: 'Saved to $localPath',
      );
    }
  }

  // ───────── Progress helpers ─────────

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Show a progress dialog for byte-level file transfers.
  Future<void> _runFileTransfer({
    required String label,
    required Future<void> Function(void Function(int, int)) transfer,
    required String successMsg,
  }) async {
    final notifier = ValueNotifier<(int, int)>((0, 0));

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(label),
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: notifier,
            builder: (_, progress, __) {
              final (sent, total) = progress;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: total > 0 ? sent / total : null),
                  const SizedBox(height: 8),
                  Text(
                    total > 0 ? '${_fmtBytes(sent)} / ${_fmtBytes(total)}' : 'Starting…',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    try {
      await transfer((s, t) { if (mounted) notifier.value = (s, t); });
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(successMsg)));
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      notifier.dispose();
    }
  }

  /// Show a progress dialog for folder transfers (shows current file name).
  Future<void> _runFolderTransfer({
    required String label,
    required Future<void> Function(void Function(String)) transfer,
    required String successMsg,
  }) async {
    final notifier = ValueNotifier<String>('');

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(label),
          content: ValueListenableBuilder<String>(
            valueListenable: notifier,
            builder: (_, file, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(
                  file.isEmpty ? 'Starting…' : file.split('/').last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      await transfer((f) { if (mounted) notifier.value = f; });
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(successMsg)));
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      notifier.dispose();
    }
  }

  // ───────── Build ─────────

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    _syncCurrentPath(state);
    return Scaffold(
      appBar: AppBar(
        title: const Text('File Editor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file),
            onPressed: state.isConnected ? _showUploadSheet : null,
            tooltip: 'Upload file or folder',
          ),
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: state.isConnected ? _showDownloadPicker : null,
            tooltip: 'Download file or folder',
          ),
          _isSaving
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.save),
                  onPressed: _contentController.text.isNotEmpty ? _saveFile : null,
                  tooltip: 'Save File',
                ),
          const ThemeSwitchButton(),
          const ConnectionButton(),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pathController,
                    decoration: InputDecoration(
                      labelText: 'File Path (e.g. ~/config.json)',
                      prefixIcon: IconButton(
                        icon: const Icon(Icons.folder_open),
                        onPressed: () async {
                          final path = await showDialog<String>(
                            context: context,
                            builder: (c) => RemotePathPickerDialog(
                              initialPath: _pathController.text,
                              foldersOnly: false,
                            ),
                          );
                          if (path != null) {
                            _pathController.text = path;
                            final parent = path.contains('/')
                                ? path.substring(0, path.lastIndexOf('/'))
                                : path;
                            if (parent.isNotEmpty) state.setCurrentPath(parent);
                            _loadFile();
                          }
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                ElevatedButton.icon(
                  onPressed: _isLoading ? null : _loadFile,
                  icon: _isLoading
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.download_for_offline),
                  label: const Text('Load'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderLight),
                ),
                child: TextField(
                  controller: _contentController,
                  maxLines: null,
                  expands: true,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'File content will appear here…',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    fillColor: Colors.transparent,
                    contentPadding: EdgeInsets.all(16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
