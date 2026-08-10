import 'package:flutter/material.dart';
import '../services/sms_gateway_bridge.dart';
import '../theme/rm_theme.dart';

/// Lets the person turn *this* phone into the SMS gateway: request
/// SMS permissions, start the foreground service, and see whether
/// it's actually online. Anyone can open this screen, but only makes
/// sense to run on the one device that has the SIM you want to bridge
/// through — starting it elsewhere just registers a second, separate
/// gateway with no SMS traffic of its own.
class GatewaySetupScreen extends StatefulWidget {
  GatewaySetupScreen({super.key});

  @override
  State<GatewaySetupScreen> createState() => _GatewaySetupScreenState();
}

class _GatewaySetupScreenState extends State<GatewaySetupScreen> {
  final _bridge = SmsGatewayBridge.instance;
  GatewayStatus _status = GatewayStatus.stopped;
  bool _busy = false;
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    _status = _bridge.status;
    _bridge.statusStream.listen((s) {
      if (mounted) setState(() => _status = s);
    });
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    try {
      if (_bridge.isRunning) {
        await _bridge.stop();
      } else {
        final granted = await _bridge.requestPermissions();
        if (!granted) {
          setState(() => _permissionDenied = true);
          return;
        }
        setState(() => _permissionDenied = false);
        await _bridge.start();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _status == GatewayStatus.online;

    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        title: Text('SMS Gateway'),
        backgroundColor: RMColors.background,
      ),
      body: ListView(
        padding: EdgeInsets.all(20),
        children: [
          Container(
            padding: EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: RMColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: RMColors.border),
            ),
            child: Row(
              children: [
                Icon(
                  running
                      ? Icons.sms_rounded
                      : (_status == GatewayStatus.error
                          ? Icons.error_outline_rounded
                          : Icons.sms_outlined),
                  color: running
                      ? Colors.greenAccent
                      : (_status == GatewayStatus.error
                          ? Colors.redAccent
                          : RMColors.textSecondary),
                  size: 32,
                ),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _statusLabel(_status),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: RMColors.textPrimary,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        running
                            ? 'This phone is relaying SMS for your account.'
                            : 'Turn this on to use this phone\'s SIM as the SMS bridge.',
                        style: TextStyle(fontSize: 12, color: RMColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 20),
          ElevatedButton(
            onPressed: _busy ? null : _toggle,
            style: ElevatedButton.styleFrom(
              backgroundColor: running ? Colors.redAccent : RMColors.primary,
              foregroundColor: Colors.white,
              minimumSize: Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: _busy
                ? SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(running ? 'Turn off Gateway mode' : 'Turn on Gateway mode'),
          ),
          if (_permissionDenied) ...[
            SizedBox(height: 12),
            Text(
              'SMS permission was denied, so this phone can\'t send or read texts. '
              'Enable it from system Settings > Apps > Reality Merge > Permissions, then try again.',
              style: TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ],
          if (_status == GatewayStatus.error && _bridge.lastError != null) ...[
            SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
              ),
              child: Text(
                _bridge.lastError!,
                style: TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ),
            SizedBox(height: 4),
            Text(
              'If this mentions a missing function or "does not exist", the '
              'v14-migration.sql file hasn\'t been run in Supabase yet.',
              style: TextStyle(color: RMColors.textSecondary, fontSize: 11),
            ),
          ],
          SizedBox(height: 28),
          Text('How this works',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: RMColors.textPrimary)),
          SizedBox(height: 8),
          _InfoLine(
            icon: Icons.sim_card_outlined,
            text: 'Needs an active SIM with SMS service on this phone.',
          ),
          _InfoLine(
            icon: Icons.wifi_rounded,
            text: 'Should stay connected to the internet so it can sync new messages both ways.',
          ),
          _InfoLine(
            icon: Icons.battery_charging_full_rounded,
            text: 'Keeping this phone plugged in and excluded from battery optimization keeps it reliable.',
          ),
          _InfoLine(
            icon: Icons.info_outline_rounded,
            text: 'If the phone restarts or the app is force-stopped, open Reality Merge once here to bring the gateway back online.',
          ),
        ],
      ),
    );
  }

  String _statusLabel(GatewayStatus s) {
    switch (s) {
      case GatewayStatus.online:
        return 'Gateway is online';
      case GatewayStatus.starting:
        return 'Starting...';
      case GatewayStatus.missingPermissions:
        return 'Missing SMS permissions';
      case GatewayStatus.error:
        return 'Could not start';
      case GatewayStatus.stopped:
        return 'Gateway is off';
    }
  }
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoLine({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: RMColors.textSecondary),
          SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 12.5, color: RMColors.textSecondary)),
          ),
        ],
      ),
    );
  }
}
