import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/rm_theme.dart';

class _ToastState {
  final String fileName;
  final double progress; // 0.0 - 1.0
  final int fileIndex; // 1-based
  final int fileCount;
  final bool done;
  final bool failed;

  _ToastState({
    required this.fileName,
    required this.progress,
    required this.fileIndex,
    required this.fileCount,
    this.done = false,
    this.failed = false,
  });
}

/// A small "toast" banner pinned to the top of the screen that shows
/// live upload progress for one or more files (photo/video/document),
/// then fades itself out automatically once the batch finishes.
///
/// Usage:
/// ```dart
/// final toast = UploadProgressToast(context);
/// toast.show();
/// toast.update(fileName: 'sunset.jpg', fileIndex: 1, fileCount: 2, progress: 0.4);
/// ...
/// await toast.finish(); // or toast.fail('message')
/// ```
class UploadProgressToast {
  UploadProgressToast(this._context);

  final BuildContext _context;
  OverlayEntry? _entry;
  final ValueNotifier<_ToastState> _state = ValueNotifier(
    _ToastState(fileName: '', progress: 0, fileIndex: 1, fileCount: 1),
  );

  void show({
    required String fileName,
    required int fileCount,
  }) {
    if (_entry != null) return;
    _state.value = _ToastState(
      fileName: fileName,
      progress: 0,
      fileIndex: 1,
      fileCount: fileCount,
    );
    final overlay = Overlay.of(_context, rootOverlay: true);
    _entry = OverlayEntry(builder: (ctx) {
      return _ToastOverlay(state: _state);
    });
    overlay.insert(_entry!);
  }

  void update({
    required String fileName,
    required int fileIndex,
    required int fileCount,
    required double progress,
  }) {
    _state.value = _ToastState(
      fileName: fileName,
      fileIndex: fileIndex,
      fileCount: fileCount,
      progress: progress.clamp(0.0, 1.0),
    );
  }

  Future<void> finish() async {
    _state.value = _ToastState(
      fileName: _state.value.fileName,
      fileIndex: _state.value.fileIndex,
      fileCount: _state.value.fileCount,
      progress: 1.0,
      done: true,
    );
    await Future.delayed(Duration(milliseconds: 900));
    _dismiss();
  }

  Future<void> fail(String message) async {
    _state.value = _ToastState(
      fileName: message,
      fileIndex: _state.value.fileIndex,
      fileCount: _state.value.fileCount,
      progress: _state.value.progress,
      failed: true,
    );
    await Future.delayed(Duration(seconds: 2));
    _dismiss();
  }

  void _dismiss() {
    _entry?.remove();
    _entry = null;
  }
}

class _ToastOverlay extends StatefulWidget {
  final ValueNotifier<_ToastState> state;
  _ToastOverlay({required this.state});

  @override
  State<_ToastOverlay> createState() => _ToastOverlayState();
}

class _ToastOverlayState extends State<_ToastOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 260),
  )..forward();

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    return Positioned(
      top: topPad + 8,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(0, -1.2),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic)),
        child: FadeTransition(
          opacity: _entrance,
          child: Material(
            color: Colors.transparent,
            child: ValueListenableBuilder<_ToastState>(
              valueListenable: widget.state,
              builder: (context, s, __) {
                return Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: RMColors.surface.withOpacity(0.97),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: s.failed ? RMColors.danger : RMColors.border,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.35),
                        blurRadius: 18,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      _StatusIcon(state: s),
                      SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    s.failed
                                        ? 'Upload failed'
                                        : (s.done
                                            ? 'Upload complete'
                                            : s.fileName),
                                    style: TextStyle(
                                      color: RMColors.textPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (s.fileCount > 1 && !s.done && !s.failed)
                                  Text(
                                    '${s.fileIndex}/${s.fileCount}',
                                    style: TextStyle(
                                      color: RMColors.textSecondary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                              ],
                            ),
                            if (s.failed) ...[
                              SizedBox(height: 2),
                              Text(
                                s.fileName,
                                style: TextStyle(
                                    color: RMColors.textSecondary,
                                    fontSize: 11),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ] else ...[
                              SizedBox(height: 8),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: s.progress,
                                  minHeight: 5,
                                  backgroundColor: RMColors.surfaceAlt,
                                  valueColor: AlwaysStoppedAnimation(
                                    s.done
                                        ? RMColors.success
                                        : RMColors.primary,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      SizedBox(width: 10),
                      Text(
                        s.failed ? '' : '${(s.progress * 100).round()}%',
                        style: TextStyle(
                          color: s.done
                              ? RMColors.success
                              : RMColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final _ToastState state;
  _StatusIcon({required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.failed) {
      return Icon(Icons.error_outline_rounded,
          color: RMColors.danger, size: 20);
    }
    if (state.done) {
      return Icon(Icons.check_circle_rounded,
          color: RMColors.success, size: 20);
    }
    return SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(
        strokeWidth: 2.2,
        color: RMColors.primary,
      ),
    );
  }
}
