import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';

class RemotePathPickerDialog extends StatefulWidget {
  final String initialPath;
  final bool foldersOnly;
  /// When true, shows a "Select This Folder" button even when [foldersOnly] is false,
  /// allowing the caller to receive either a file path or the current directory path.
  final bool showSelectDir;

  const RemotePathPickerDialog({
    super.key,
    required this.initialPath,
    this.foldersOnly = false,
    this.showSelectDir = false,
  });

  @override
  State<RemotePathPickerDialog> createState() => _RemotePathPickerDialogState();
}

class _RemotePathPickerDialogState extends State<RemotePathPickerDialog> {
  late String _currentPath;
  List<String> _items = [];
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final state = Provider.of<AppState>(context, listen: false);
    // Resolve ~ to actual home directory
    String initial = widget.initialPath.isEmpty ? '~' : widget.initialPath;
    _currentPath = state.sshService.resolvePath(initial);
    _loadDirectory();
  }

  Future<void> _loadDirectory() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final state = Provider.of<AppState>(context, listen: false);
      // Use resolved absolute path (no tilde)
      String cmd = widget.foldersOnly 
          ? 'ls -d "$_currentPath"/*/ 2>/dev/null || echo ""'
          : 'ls -p "$_currentPath" 2>/dev/null || echo ""';
          
      final output = await state.sshService.executeCommand(cmd);
      
      final lines = output.trim().split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      
      // For foldersOnly with full paths, extract just the basename
      List<String> displayItems;
      if (widget.foldersOnly) {
        displayItems = lines.map((l) {
          // Extract last path component
          final parts = l.split('/').where((p) => p.isNotEmpty).toList();
          return parts.isNotEmpty ? '${parts.last}/' : l;
        }).toList();
      } else {
        displayItems = lines;
      }

      setState(() {
        _items = displayItems;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _navigateUp() {
    if (_currentPath == '/') return;
    // Go to parent directory
    final parts = _currentPath.split('/');
    parts.removeLast();
    _currentPath = parts.isEmpty ? '/' : parts.join('/');
    if (_currentPath.isEmpty) _currentPath = '/';
    _loadDirectory();
  }

  void _onItemTap(String item) {
    if (item.endsWith('/')) {
       // It's a directory, go into it
       final dirName = item.replaceAll('/', '');
       _currentPath = _currentPath == '/' ? '/$dirName' : '$_currentPath/$dirName';
       _loadDirectory();
    } else {
       // It's a file, select it
       final fullPath = _currentPath == '/' ? '/$item' : '$_currentPath/$item';
       Navigator.of(context).pop(fullPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 400,
        height: 500,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: _navigateUp,
                  tooltip: 'Go Up',
                ),
                Expanded(
                  child: Text(
                    _currentPath,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.foldersOnly || widget.showSelectDir)
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(_currentPath),
                    child: Text(widget.foldersOnly ? 'Select' : 'Select Folder'),
                  )
              ],
            ),
            const Divider(),
            Expanded(
              child: _isLoading 
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                  ? Center(child: Text('Error: $_error', style: const TextStyle(color: Colors.red)))
                  : _items.isEmpty 
                    ? const Center(child: Text('Empty directory'))
                    : ListView.builder(
                        itemCount: _items.length,
                        itemBuilder: (context, index) {
                          final item = _items[index];
                          final isDir = item.endsWith('/');
                          return ListTile(
                            leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file, color: isDir ? Colors.blue : null),
                            title: Text(item),
                            onTap: () => _onItemTap(item),
                          );
                        },
                      ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            )
          ],
        ),
      ),
    );
  }
}
