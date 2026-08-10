import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:ar_flutter_plugin_2/ar_flutter_plugin.dart';
import 'package:ar_flutter_plugin_2/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_2/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_2/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_2/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_2/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_2/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_2/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_2/models/ar_node.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import '../models/drop.dart';
import '../services/drop_events.dart';
import '../services/location_service.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/emoji_input.dart';
import 'drop_detail_screen.dart';

class ARScreen extends StatefulWidget {
  const ARScreen({super.key});

  @override
  State<ARScreen> createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> with TickerProviderStateMixin {
  // AR managers
  ARSessionManager? _sessionManager;
  ARObjectManager? _objectManager;
  ARAnchorManager? _anchorManager;

  // State
  geo.Position? _position;
  List<Drop> _drops = [];
  bool _arReady = false;
  bool _hasPermission = false;
  bool _planeDetected = false;
  bool _loading = true;
  String? _error;
  String _statusMessage = 'Move camera to detect surfaces…';

  // Compass
  double _heading = 0;
  StreamSubscription? _compassSub;
  StreamSubscription? _dropCreatedSub;

  // Placed anchors map: drop.id → anchor
  final Map<String, ARAnchor> _anchors = {};
  // Placed anchors' confirmed surface label: drop.id → label (e.g. "Table")
  // Not persisted server-side yet — see note in _showSurfaceConfirmSheet.
  final Map<String, String> _anchorLabels = {};

  // On-device surface classifier. Created lazily on first use since it
  // loads a model file — no need to pay that cost if the user never
  // places anything in Surface mode.
  ImageLabeler? _imageLabeler;
  bool _classifying = false;

  // Place-drop mode
  bool _placingMode = false;
  Drop? _dropToPlace;

  // Pulse animation for scan ring
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  // Mode toggle
  bool _overlayMode = true; // true = compass overlay, false = ARCore plane

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnim = CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut);
    _dropCreatedSub = DropEvents.instance.onDropCreated.listen((_) {
      // ARScreen may be kept alive in HomeShell's IndexedStack even
      // while another tab is visible — refetch so drops are current
      // next time this tab is shown, without waiting for a full
      // re-init.
      _refetchNearbyDrops();
    });
    _init();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _compassSub?.cancel();
    _dropCreatedSub?.cancel();
    _sessionManager?.dispose();
    _imageLabeler?.close();
    super.dispose();
  }

  Future<void> _init() async {
    // Request camera + location permissions
    final cam = await Permission.camera.request();
    final loc = await Permission.locationWhenInUse.request();

    if (!cam.isGranted || !loc.isGranted) {
      setState(() {
        _error = 'Camera and location permissions are required for AR mode.';
        _loading = false;
      });
      return;
    }

    setState(() { _hasPermission = true; _loading = false; });

    // Start compass
    _compassSub = magnetometerEventStream().listen((event) {
      final heading = math.atan2(event.y, event.x) * (180 / math.pi);
      setState(() => _heading = (heading + 360) % 360);
    });

    // Get location + drops
    try {
      final position = await LocationService.instance.getCurrentPosition();
      setState(() => _position = position);
      await _refetchNearbyDrops();
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _refetchNearbyDrops() async {
    if (_position == null) return;
    try {
      final drops = await SupabaseService.instance.fetchNearbyDrops(
        lat: _position!.latitude,
        lng: _position!.longitude,
        radiusM: 200, // AR mode — only very nearby drops
      );
      if (mounted) setState(() => _drops = drops);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  // ── ARCore callbacks ─────────────────────────────────────────────────────

  void _onARViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    _sessionManager = sessionManager;
    _objectManager = objectManager;
    _anchorManager = anchorManager;

    sessionManager.onInitialize(
      showAnimatedGuide: false,
      showFeaturePoints: true,
      showPlanes: true,
      customPlaneTexturePath: null,
      showWorldOrigin: false,
      handlePans: false,
      handleRotation: false,
    );

    objectManager.onInitialize();

    sessionManager.onPlaneOrPointTap = _onPlaneTap;

    setState(() => _arReady = true);
  }

  Future<void> _onPlaneTap(List<ARHitTestResult> hits) async {
    if (!_placingMode || _dropToPlace == null) {
      // Not in place mode — show status
      setState(() {
        _planeDetected = true;
        _statusMessage = 'Surface detected! Select a drop to place.';
      });
      return;
    }

    if (_classifying) return; // ignore taps while a scan is in flight

    final hit = hits.firstWhere(
      (h) => h.type == ARHitTestResultType.plane,
      orElse: () => hits.first,
    );

    setState(() {
      _classifying = true;
      _statusMessage = 'Scanning surface…';
    });

    List<ImageLabel> labels = [];
    try {
      final bytes = await _captureArSnapshotBytes();
      if (bytes != null) {
        labels = await _classifySnapshot(bytes);
      }
    } catch (e) {
      debugPrint('Surface scan error: $e');
      // Fall through with an empty label list — the confirm sheet still
      // lets the user pick manually, so a classification failure
      // doesn't block placement.
    }

    if (!mounted) return;
    setState(() => _classifying = false);

    final confirmedLabel = await _showSurfaceConfirmSheet(labels);
    if (confirmedLabel == null) {
      // User cancelled — stay in placing mode, don't place anything.
      setState(() => _statusMessage = 'Tap a detected surface to place this drop');
      return;
    }

    await _placeAnchor(hit, confirmedLabel);
  }

  /// Grabs a still frame of the current AR scene via ARSessionManager's
  /// snapshot() and returns it as PNG bytes ready for ML Kit. This is the
  /// only frame-access point ar_flutter_plugin_2 exposes — there's no
  /// live video stream out of the plugin, so classification only happens
  /// at the moment of a tap, not continuously.
  Future<Uint8List?> _captureArSnapshotBytes() async {
    if (_sessionManager == null) return null;
    final provider = await _sessionManager!.snapshot();

    final completer = Completer<ui.Image>();
    final stream = provider.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (err, st) {
        if (!completer.isCompleted) completer.completeError(err, st);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);

    final uiImage = await completer.future;
    final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  Future<List<ImageLabel>> _classifySnapshot(Uint8List pngBytes) async {
    _imageLabeler ??= ImageLabeler(
      options: ImageLabelerOptions(confidenceThreshold: 0.4),
    );

    // ML Kit's InputImage reads most reliably from a file path — write
    // the snapshot to a scratch temp file, classify, then clean up.
    final file = File(
      '${Directory.systemTemp.path}/rm_ar_snapshot_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(pngBytes);
    try {
      final labels = await _imageLabeler!.processImage(
        InputImage.fromFilePath(file.path),
      );
      labels.sort((a, b) => b.confidence.compareTo(a.confidence));
      return labels.take(3).toList();
    } finally {
      unawaited(file.delete().catchError((_) {}));
    }
  }

  /// Shows the AI's best guesses and lets the user confirm one, pick a
  /// quick alternative, or type a custom label. Returns the confirmed
  /// label, or null if the user cancelled.
  Future<String?> _showSurfaceConfirmSheet(List<ImageLabel> labels) async {
    final customCtrl = TextEditingController();
    const quickPicks = ['Table', 'Chair', 'Shelf', 'Floor', 'Wall', 'Desk'];

    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: RMColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      isScrollControlled: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('What surface is this?',
                  style: TextStyle(
                      color: RMColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                labels.isEmpty
                    ? "Couldn't get a confident read — pick or type one."
                    : 'AI best guess, confirm or change it:',
                style: const TextStyle(
                    color: RMColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 14),
              if (labels.isNotEmpty)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: labels
                      .map((l) => ActionChip(
                            backgroundColor: RMColors.primaryDim,
                            label: Text(
                              '${l.label} ${(l.confidence * 100).round()}%',
                              style: const TextStyle(
                                  color: RMColors.primary,
                                  fontWeight: FontWeight.w600),
                            ),
                            onPressed: () =>
                                Navigator.of(sheetContext).pop(l.label),
                          ))
                      .toList(),
                ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: quickPicks
                    .map((p) => ActionChip(
                          backgroundColor: RMColors.surfaceAlt,
                          label: Text(p,
                              style: const TextStyle(
                                  color: RMColors.textPrimary, fontSize: 12)),
                          onPressed: () =>
                              Navigator.of(sheetContext).pop(p),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: customCtrl,
                style: const TextStyle(color: RMColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Or type your own label…',
                  hintStyle: const TextStyle(color: RMColors.textHint),
                  suffixIcon: EmojiSheetButton(controller: customCtrl),
                ),
                onSubmitted: (v) {
                  if (v.trim().isNotEmpty) {
                    Navigator.of(sheetContext).pop(v.trim());
                  }
                },
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(sheetContext).pop(null),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        final v = customCtrl.text.trim();
                        Navigator.of(sheetContext).pop(
                          v.isNotEmpty
                              ? v
                              : (labels.isNotEmpty ? labels.first.label : null),
                        );
                      },
                      child: const Text('Confirm'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _placeAnchor(ARHitTestResult hit, String surfaceLabel) async {
    final anchor = ARPlaneAnchor(transformation: hit.worldTransform);
    final didAdd = await _anchorManager!.addAnchor(anchor);
    if (didAdd != true) return;

    // Create a glowing box node
    final node = ARNode(
      type: NodeType.webGLB,
      uri: 'https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/Box/glTF-Binary/Box.glb',
      scale: vm.Vector3(0.15, 0.15, 0.15),
      position: vm.Vector3(0, 0, 0),
      rotation: vm.Vector4(0, 0, 0, 0),
    );

    final didAddNode = await _objectManager!.addNode(node, planeAnchor: anchor);
    if (didAddNode == true) {
      _anchors[_dropToPlace!.id] = anchor;
      _anchorLabels[_dropToPlace!.id] = surfaceLabel;
      setState(() {
        _placingMode = false;
        _statusMessage = 'Drop placed on "$surfaceLabel"!';
        _dropToPlace = null;
      });
    }
  }

  // ── Compass overlay helpers ───────────────────────────────────────────────

  /// Returns angle in degrees from user to drop, relative to north
  double _bearingToDrop(Drop drop) {
    if (_position == null || drop.dropLat == null || drop.dropLng == null) {
      return 0;
    }
    final lat1 = _position!.latitude * math.pi / 180;
    final lat2 = drop.dropLat! * math.pi / 180;
    final dLng = (drop.dropLng! - _position!.longitude) * math.pi / 180;
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// How far off-center a drop is relative to current heading (−180 to 180)
  double _relativeAngle(Drop drop) {
    final bearing = _bearingToDrop(drop);
    var rel = bearing - _heading;
    if (rel > 180) rel -= 360;
    if (rel < -180) rel += 360;
    return rel;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: RMColors.background,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: RMColors.primary),
              SizedBox(height: 16),
              Text('Initialising AR…',
                  style: TextStyle(color: RMColors.textSecondary)),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: RMColors.background,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    color: RMColors.danger, size: 48),
                const SizedBox(height: 16),
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: RMColors.textSecondary)),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    await openAppSettings();
                  },
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── AR view or compass overlay ──────────────────────────
          if (!_overlayMode && _hasPermission)
            ARView(
              onARViewCreated: _onARViewCreated,
              planeDetectionConfig:
                  PlaneDetectionConfig.horizontalAndVertical,
            )
          else
            _buildCompassOverlay(),

          // ── Top bar ─────────────────────────────────────────────
          Positioned(
            top: MediaQuery.of(context).padding.top,
            left: 0,
            right: 0,
            child: _buildTopBar(),
          ),

          // ── Mode toggle ─────────────────────────────────────────
          Positioned(
            top: MediaQuery.of(context).padding.top + 60,
            left: 0,
            right: 0,
            child: Center(child: _buildModeToggle()),
          ),

          // ── Status message ──────────────────────────────────────
          if (!_overlayMode)
            Positioned(
              top: MediaQuery.of(context).padding.top + 120,
              left: 24,
              right: 24,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _statusMessage,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),

          // ── Drop list panel ─────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildDropPanel(),
          ),

          // ── Scan ring (overlay mode) ─────────────────────────────
          if (_overlayMode)
            Center(child: _buildScanRing()),
        ],
      ),
    );
  }

  // ── Compass overlay ───────────────────────────────────────────────────────

  Widget _buildCompassOverlay() {
    final size = MediaQuery.of(context).size;
    return Stack(
      children: [
        // Camera-like dark background
        Container(color: Colors.black),

        // Horizon line
        Positioned(
          top: size.height * 0.42,
          left: 0,
          right: 0,
          child: Container(
            height: 1,
            color: RMColors.primary.withOpacity(0.3),
          ),
        ),

        // Drop directional indicators
        ..._drops
            .where((d) => d.dropLat != null && d.dropLng != null)
            .map((d) => _buildDropIndicator(d, size)),
      ],
    );
  }

  Widget _buildDropIndicator(Drop drop, Size size) {
    final rel = _relativeAngle(drop);
    // Only show drops within ±60° of current heading
    if (rel.abs() > 60) return const SizedBox.shrink();

    final x = size.width / 2 + (rel / 60) * (size.width / 2.5);
    final y = size.height * 0.4 -
        (1 - drop.distanceM / 200).clamp(0, 1).toDouble() * size.height * 0.15;

    return Positioned(
      left: x - 40,
      top: y - 40,
      child: GestureDetector(
        onTap: () {
          if (_position == null) return;
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => DropDetailScreen(
              drop: drop,
              currentLat: _position!.latitude,
              currentLng: _position!.longitude,
            ),
          ));
        },
        child: Column(
          children: [
            AnimatedBuilder(
              animation: _pulseAnim,
              builder: (_, __) => Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: (drop.isUnlocked
                          ? RMColors.success
                          : RMColors.primary)
                      .withOpacity(0.15 + _pulseAnim.value * 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: drop.isUnlocked
                        ? RMColors.success
                        : RMColors.primary,
                    width: 2,
                  ),
                ),
                child: Icon(
                  drop.isUnlocked
                      ? Icons.lock_open_rounded
                      : Icons.lock_rounded,
                  color: drop.isUnlocked
                      ? RMColors.success
                      : RMColors.primary,
                  size: 24,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                drop.distanceLabel,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScanRing() {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (_, __) => Container(
        width: 200,
        height: 200,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: RMColors.primary
                .withOpacity(0.3 + _pulseAnim.value * 0.3),
            width: 1.5,
          ),
        ),
        child: Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: RMColors.primary
                    .withOpacity(0.5 + _pulseAnim.value * 0.3),
                width: 1,
              ),
            ),
            child: const Center(
              child: Icon(Icons.add, color: RMColors.primary, size: 28),
            ),
          ),
        ),
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(10),
            ),
            child: IconButton(
              icon: const Icon(Icons.arrow_back_rounded,
                  color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: RMColors.success,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${_drops.length} drops in range',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Mode toggle ────────────────────────────────────────────────────────────

  Widget _buildModeToggle() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToggleBtn(
            label: 'Compass',
            icon: Icons.explore_rounded,
            selected: _overlayMode,
            onTap: () => setState(() => _overlayMode = true),
          ),
          _ToggleBtn(
            label: 'Surface',
            icon: Icons.view_in_ar_rounded,
            selected: !_overlayMode,
            onTap: () => setState(() => _overlayMode = false),
          ),
        ],
      ),
    );
  }

  // ── Drop panel ─────────────────────────────────────────────────────────────

  Widget _buildDropPanel() {
    return Container(
      decoration: BoxDecoration(
        color: RMColors.surface.withOpacity(0.95),
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(24)),
        border: const Border(top: BorderSide(color: RMColors.border)),
      ),
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: RMColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text('Nearby Drops',
              style: TextStyle(
                  color: RMColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14)),
          const SizedBox(height: 10),
          if (_drops.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No drops within 200m.',
                  style: TextStyle(
                      color: RMColors.textSecondary, fontSize: 13)),
            )
          else
            SizedBox(
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _drops.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: 10),
                itemBuilder: (context, i) =>
                    _DropChip(
                  drop: _drops[i],
                  onTap: () {
                    if (!_overlayMode) {
                      // Surface mode — enter place mode
                      setState(() {
                        _placingMode = true;
                        _dropToPlace = _drops[i];
                        _statusMessage =
                            'Tap a detected surface to place this drop';
                      });
                    } else {
                      // Compass mode — open detail
                      if (_position == null) return;
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => DropDetailScreen(
                          drop: _drops[i],
                          currentLat: _position!.latitude,
                          currentLng: _position!.longitude,
                        ),
                      ));
                    }
                  },
                  placing: _placingMode &&
                      _dropToPlace?.id == _drops[i].id,
                ),
              ),
            ),
          if (_placingMode)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: OutlinedButton(
                onPressed: () => setState(() {
                  _placingMode = false;
                  _dropToPlace = null;
                  _statusMessage = 'Move camera to detect surfaces…';
                }),
                child: const Text('Cancel placement'),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToggleBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ToggleBtn({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? RMColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 14,
                color: selected
                    ? Colors.white
                    : RMColors.textSecondary),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    color: selected
                        ? Colors.white
                        : RMColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _DropChip extends StatelessWidget {
  final Drop drop;
  final VoidCallback onTap;
  final bool placing;

  const _DropChip({
    required this.drop,
    required this.onTap,
    required this.placing,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 130,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: placing ? RMColors.primaryDim : RMColors.surfaceAlt,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: placing ? RMColors.primary : RMColors.border,
            width: placing ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              drop.isUnlocked
                  ? Icons.lock_open_rounded
                  : Icons.lock_rounded,
              size: 16,
              color: drop.isUnlocked
                  ? RMColors.success
                  : RMColors.textHint,
            ),
            const Spacer(),
            Text(
              drop.isUnlocked
                  ? (drop.caption ?? 'Drop')
                  : 'Locked drop',
              style: const TextStyle(
                  color: RMColors.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              drop.distanceLabel,
              style: const TextStyle(
                  color: RMColors.textSecondary, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}
