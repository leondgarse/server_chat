import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../utils/theme.dart';
import '../widgets/remote_path_picker.dart';
import '../widgets/connection_button.dart';

class FileEditTab extends StatefulWidget {
  const FileEditTab({super.key});

  @override
  State<FileEditTab> createState() => _FileEditTabState();
}

class _FileEditTabState extends State<FileEditTab> {
  final TextEditingController _pathController = TextEditingController(text: '~');
  final TextEditingController _contentController = TextEditingController();
  
  bool _isLoading = false;
  bool _isSaving = false;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('File Editor'),
        actions: [
          _isSaving
            ? const Center(child: Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))))
            : IconButton(
                icon: const Icon(Icons.save),
                onPressed: _contentController.text.isNotEmpty ? _saveFile : null,
                tooltip: 'Save File',
              ),
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
                             builder: (c) => RemotePathPickerDialog(initialPath: _pathController.text, foldersOnly: false),
                           );
                           if (path != null) {
                             _pathController.text = path;
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
                  icon: _isLoading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.download),
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
                    hintText: 'File content will appear here...',
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
