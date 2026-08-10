import 'package:flutter/material.dart';
import '../models/drop.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';

/// Bottom sheet for redropping a Drop — a lightweight, permanent
/// repost record with an optional short requote, mirroring
/// [NewsRedropSheet]'s in-app repost half but scoped to a single
/// action (no share-to-status capture) to keep this a quick tap
/// rather than a whole flow. See v22-migration.sql / drop_redrops.
class DropRedropSheet extends StatefulWidget {
  final Drop drop;
  const DropRedropSheet({super.key, required this.drop});

  @override
  State<DropRedropSheet> createState() => _DropRedropSheetState();
}

class _DropRedropSheetState extends State<DropRedropSheet> {
  final _quoteCtrl = TextEditingController();
  bool _busy = false;
  bool _loadingExisting = true;
  bool _alreadyRedropped = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    try {
      final existing =
          await SupabaseService.instance.fetchMyDropRedrop(widget.drop.id);
      if (existing != null && mounted) {
        setState(() {
          _alreadyRedropped = true;
          _quoteCtrl.text = existing['quote'] as String? ?? '';
        });
      }
    } catch (_) {
      // Same fallback as NewsRedropSheet — worst case the button just
      // starts out reading "Redrop" instead of "Update redrop".
    } finally {
      if (mounted) setState(() => _loadingExisting = false);
    }
  }

  @override
  void dispose() {
    _quoteCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final quote = _quoteCtrl.text.trim();
      await SupabaseService.instance.addOrUpdateDropRedrop(
        dropId: widget.drop.id,
        quote: quote.isEmpty ? null : quote,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _undo() async {
    setState(() => _busy = true);
    try {
      await SupabaseService.instance.removeDropRedrop(widget.drop.id);
      if (mounted) Navigator.of(context).pop(false);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.repeat_rounded, color: RMColors.primary, size: 20),
              SizedBox(width: 8),
              Text(
                _alreadyRedropped ? 'Update redrop' : 'Redrop',
                style: TextStyle(
                    color: RMColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 17),
              ),
            ],
          ),
          SizedBox(height: 6),
          Text(
            'by ${widget.drop.creatorUsername}${widget.drop.caption != null && widget.drop.caption!.isNotEmpty ? " · ${widget.drop.caption}" : ""}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: RMColors.textSecondary, fontSize: 13),
          ),
          SizedBox(height: 16),
          if (_loadingExisting)
            Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: RMColors.primary),
              ),
            )
          else ...[
            TextField(
              controller: _quoteCtrl,
              maxLength: 280,
              maxLines: 3,
              style: TextStyle(color: RMColors.textPrimary),
              decoration: InputDecoration(
                labelText: 'Add a note (optional)',
                counterStyle: TextStyle(color: RMColors.textHint),
              ),
            ),
            if (_error != null) ...[
              SizedBox(height: 6),
              Text(_error!,
                  style: TextStyle(color: RMColors.danger, fontSize: 12)),
            ],
            SizedBox(height: 12),
            Row(
              children: [
                if (_alreadyRedropped)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _undo,
                      child: Text('Remove redrop'),
                    ),
                  ),
                if (_alreadyRedropped) SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                        backgroundColor: RMColors.primary),
                    child: _busy
                        ? SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Text(_alreadyRedropped ? 'Update' : 'Redrop'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
