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

    return Tooltip(
      message: connected ? 'Connected' : 'Tap to connect',
      child: IconButton(
        icon: Icon(
          connected ? Icons.link : Icons.link_off,
          color: connected ? Colors.green : Colors.grey,
        ),
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
