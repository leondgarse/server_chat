import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/app_state.dart';
import '../utils/text_truncator.dart';
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
  final FocusNode _pathFocus = FocusNode();
  bool _pathFocused = false;
  bool _isLoading = false;
  bool _isSaving = false;
  bool _isUploading = false;
  bool _isDownloading = false;
  double _uploadProgress = 0.0;
  String _lastKnownPath = '';

  @override
  void initState() {
    super.initState();
    _contentController.addListener(() => setState(() {}));
    _pathFocus.addListener(() => setState(() => _pathFocused = _pathFocus.hasFocus));
    _pathController.addListener(() => setState(() {}));
  }

  void _setPath(String path) {
    _pathController.text = path;
  }

  @override
  void dispose() {
    _pathController.dispose();
    _pathFocus.dispose();
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
        if (mounted) _setPath(state.currentPath);
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

    // Check if file already exists
    final fileExists = await state.sshService.isRemoteFile(remotePath);

    if (fileExists) {
      final shouldOverwrite = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('File Exists'),
          content: Text('File "$fileName" already exists. Overwrite it?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Overwrite'),
            ),
          ],
        ),
      );

      if (shouldOverwrite != true || !mounted) return;
    }

    final notifier = ValueNotifier<double>(0.0);
    setState(() {
      _isUploading = true;
      _uploadProgress = 0.0;
    });

    await state.sshService.uploadFile(localPath, remotePath, onProgress: (current, total) async {
      if (total > 0) {
        final progress = current / total;
        if (mounted) {
          setState(() => _uploadProgress = progress);
          notifier.value = progress;
        }
      }
    });

    if (mounted) {
      setState(() => _isUploading = false);
      notifier.dispose();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Uploaded to $remotePath')));
    }
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

    final notifier = ValueNotifier<String>('');

    setState(() {
      _isUploading = true;
      _uploadProgress = 0.0;
    });

    await state.sshService.uploadDirectory(dirPath, remoteDir, onProgress: (file, progress) {
      if (mounted) {
        notifier.value = file;
        setState(() => _uploadProgress = progress);
      }
    });

    if (mounted) {
      setState(() => _isUploading = false);
      notifier.dispose();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Uploaded $dirName/ to $remoteDir')));
    }
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
    final localPath = '${docsDir.path.endsWith('/') ? docsDir.path.substring(0, docsDir.path.length - 1) : docsDir.path}/$name';
    final localExists = isDir ? Directory(localPath).existsSync() : File(localPath).existsSync();

    if (localExists && mounted) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Overwrite?'),
          content: Text('"$name" already exists locally.\nOverwrite it?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Overwrite')),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }

    setState(() => _isDownloading = true);
    try {
      if (isDir) {
        await state.sshService.downloadDirectory(remotePath, docsDir.path, onProgress: (file) {});
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to $localPath')));
      } else {
        await state.sshService.downloadFile(remotePath, localPath, onProgress: (received, total) {});
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to $localPath')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isDownloading = false);
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
          Stack(
            alignment: Alignment.center,
            children: [
              if (_isUploading)
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(2.0),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: _uploadProgress,
                      color: AppTheme.primaryBlue,
                      backgroundColor: Colors.transparent,
                    ),
                  ),
                ),
              IconButton(
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _isUploading
                      ? const SizedBox(
                          key: ValueKey('uploading'),
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(
                          key: ValueKey('upload_icon'),
                          Icons.upload_file,
                        ),
                ),
                onPressed: state.isConnected ? _showUploadSheet : null,
                tooltip: _isUploading ? 'Uploading...' : 'Upload file or folder',
              ),
            ],
          ),
          _isDownloading
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                )
              : IconButton(
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
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final style = Theme.of(context).textTheme.bodyMedium!.copyWith(fontSize: 14);
                      // prefixIcon=48, internal content padding≈12 each side
                      const textStart = 60.0;
                      const textEnd = 12.0;
                      final availableWidth = constraints.maxWidth - textStart - textEnd;
                      final truncated = !_pathFocused
                          ? truncateLeft(_pathController.text, availableWidth, style)
                          : _pathController.text;
                      return Stack(
                        children: [
                          TextField(
                            controller: _pathController,
                            focusNode: _pathFocus,
                            textAlign: TextAlign.left,
                            textAlignVertical: TextAlignVertical.top,
                            maxLines: 1,
                            style: _pathFocused ? style : style.copyWith(color: Colors.transparent),
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
                                    _setPath(path);
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
                          if (!_pathFocused && _pathController.text.isNotEmpty)
                            Positioned(
                              left: textStart,
                              top: 0,
                              bottom: 0,
                              right: textEnd,
                              child: IgnorePointer(
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    truncated,
                                    maxLines: 1,
                                    overflow: TextOverflow.clip,
                                    style: style,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
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
