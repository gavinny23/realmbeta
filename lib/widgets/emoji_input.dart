import 'package:characters/characters.dart';
import 'package:flutter/material.dart';
import 'emoji_picker_panel.dart';

/// Inserts [emoji] at [controller]'s current cursor position (rather
/// than just appending to the end) and leaves the cursor right after
/// it, so picking several emoji in a row reads naturally.
void insertEmojiIntoController(TextEditingController controller, String emoji) {
  final text = controller.text;
  final selection = controller.selection;
  final start = selection.start >= 0 ? selection.start : text.length;
  final end = selection.end >= 0 ? selection.end : text.length;
  final newText = text.replaceRange(start, end, emoji);
  controller.value = TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: start + emoji.length),
  );
}

/// Deletes one full grapheme cluster before the cursor — not just one
/// UTF-16 code unit — so multi-part emoji (skin tones, ZWJ sequences
/// like 🐻‍❄️) delete as a single character instead of leaving broken
/// fragments behind.
void backspaceEmojiFromController(TextEditingController controller) {
  final text = controller.text;
  final selection = controller.selection;
  final cursor = selection.start >= 0 ? selection.start : text.length;
  if (cursor == 0) return;
  final before = text.substring(0, cursor);
  final clusters = before.characters;
  final newBefore =
      clusters.isEmpty ? before : clusters.take(clusters.length - 1).toString();
  final removedLength = before.length - newBefore.length;
  controller.value = TextEditingValue(
    text: newBefore + text.substring(cursor),
    selection: TextSelection.collapsed(offset: cursor - removedLength),
  );
}

/// Opens the app's own emoji picker as a bottom sheet for [controller].
/// Meant for text fields that live inside layouts too varied or
/// cramped (dialogs, compact overlays, forms) to swap the panel in
/// place of the keyboard inline the way the main chat composer does —
/// see `chat_conversation_screen.dart` for that inline variant.
/// Selecting an emoji doesn't close the sheet, so picking several in a
/// row works the same way it does there.
Future<void> showEmojiPickerSheet(
  BuildContext context, {
  required TextEditingController controller,
  FocusNode? focusNode,
}) async {
  focusNode?.unfocus();
  await showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      top: false,
      child: EmojiPickerPanel(
        onEmojiSelected: (e) => insertEmojiIntoController(controller, e),
        onBackspace: () => backspaceEmojiFromController(controller),
      ),
    ),
  );
}

/// A small emoji-face icon button that opens [showEmojiPickerSheet]
/// for [controller] — drop this next to (or as a `suffixIcon` on) any
/// text field that should get the app's own emoji keyboard.
class EmojiSheetButton extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final Color? color;
  final double? iconSize;
  final bool compact;

  const EmojiSheetButton({
    super.key,
    required this.controller,
    this.focusNode,
    this.color,
    this.iconSize,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.emoji_emotions_outlined, color: color, size: iconSize),
      tooltip: 'Emoji',
      padding: compact ? EdgeInsets.zero : null,
      constraints: compact ? const BoxConstraints() : null,
      onPressed: () =>
          showEmojiPickerSheet(context, controller: controller, focusNode: focusNode),
    );
  }
}
