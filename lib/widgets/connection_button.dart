import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../screens/connect_tab.dart';

class ConnectionButton extends StatelessWidget {
  const ConnectionButton({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final connected = state.isConnected;
    final connecting = state.isConnecting || state.isReconnecting;

    String tooltip;
    Widget icon;
    if (connected) {
      tooltip = 'Connected';
      icon = const Icon(Icons.link, color: Colors.green);
    } else if (connecting) {
      tooltip = 'Reconnecting…';
      icon = const SizedBox(
        width: 18, height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
      );
    } else {
      tooltip = 'Tap to connect';
      icon = const Icon(Icons.link_off, color: Colors.grey);
    }

    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: icon,
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChangeNotifierProvider.value(
                value: state,
                child: const Scaffold(
                  body: ConnectTab(),
                ),
              ),
              fullscreenDialog: true,
            ),
          );
        },
      ),
    );
  }
}
