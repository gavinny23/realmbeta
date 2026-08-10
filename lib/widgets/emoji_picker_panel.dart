import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/emoji_data.dart';
import '../theme/rm_theme.dart';

/// A self-contained emoji keyboard — no platform emoji keyboard, no
/// image assets, no network. Just Unicode characters laid out in a
/// grid with category tabs, meant to be shown in place of the system
/// keyboard (see usage in `chat_conversation_screen.dart`).
///
/// Remembers the last-used emoji locally (per device, not per
/// conversation) so frequently-reached-for ones surface first.
class EmojiPickerPanel extends StatefulWidget {
  final ValueChanged<String> onEmojiSelected;
  final VoidCallback? onBackspace;
  final double height;

  const EmojiPickerPanel({
    super.key,
    required this.onEmojiSelected,
    this.onBackspace,
    this.height = 280,
  });

  @override
  State<EmojiPickerPanel> createState() => _EmojiPickerPanelState();
}

class _EmojiPickerPanelState extends State<EmojiPickerPanel>
    with SingleTickerProviderStateMixin {
  static const _recentsKey = 'rm_recent_emoji';
  static const _maxRecents = 24;

  late TabController _tabCtrl;
  List<String> _recents = [];

  List<EmojiCategory> get _categories => [
        if (_recents.isNotEmpty)
          EmojiCategory(name: 'Recent', icon: '🕓', emojis: _recents),
        ...emojiCategories,
      ];

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: emojiCategories.length, vsync: this);
    _loadRecents();
  }

  Future<void> _loadRecents() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_recentsKey) ?? [];
      if (mounted && saved.isNotEmpty) {
        setState(() {
          _recents = saved;
          _tabCtrl.dispose();
          _tabCtrl = TabController(length: _categories.length, vsync: this);
        });
      }
    } catch (_) {
      // Recents are a nice-to-have — fine to just start without them.
    }
  }

  Future<void> _recordRecent(String emoji) async {
    setState(() {
      _recents.remove(emoji);
      _recents.insert(0, emoji);
      if (_recents.length > _maxRecents) {
        _recents = _recents.sublist(0, _maxRecents);
      }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_recentsKey, _recents);
    } catch (_) {}
  }

  void _pick(String emoji) {
    widget.onEmojiSelected(emoji);
    _recordRecent(emoji);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories;
    // The controller's length has to track _categories (which grows by
    // one once recents exist) — rebuild it rather than let it drift out
    // of sync and crash on an out-of-range tab index.
    if (_tabCtrl.length != categories.length) {
      _tabCtrl.dispose();
      _tabCtrl = TabController(length: categories.length, vsync: this);
    }

    return Container(
      height: widget.height,
      color: RMColors.surface,
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: RMColors.border)),
            ),
            child: TabBar(
              controller: _tabCtrl,
              isScrollable: true,
              indicatorColor: RMColors.primary,
              labelPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              tabs: [
                for (final c in categories)
                  Tab(child: Text(c.icon, style: TextStyle(fontSize: 20))),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                for (final c in categories) _EmojiGrid(c.emojis, onTap: _pick),
              ],
            ),
          ),
          if (widget.onBackspace != null)
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: RMColors.border)),
              ),
              child: Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  icon: Icon(Icons.backspace_outlined,
                      color: RMColors.textSecondary, size: 20),
                  onPressed: widget.onBackspace,
                  tooltip: 'Delete',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmojiGrid extends StatelessWidget {
  final List<String> emojis;
  final ValueChanged<String> onTap;

  const _EmojiGrid(this.emojis, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: EdgeInsets.all(6),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
      ),
      itemCount: emojis.length,
      itemBuilder: (context, i) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => onTap(emojis[i]),
        child: Center(
          child: Text(emojis[i], style: TextStyle(fontSize: 24)),
        ),
      ),
    );
  }
}
