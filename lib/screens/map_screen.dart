import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import '../models/drop.dart';
import '../services/drop_events.dart';
import '../services/location_service.dart';
import '../services/onboarding_service.dart';
import '../services/supabase_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/tutorial_overlay.dart';
import 'drop_detail_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  MapboxMap? _mapboxMap;
  geo.Position? _position;
  List<Drop> _drops = [];
  StreamSubscription<geo.Position>? _positionSub;
  StreamSubscription? _dropCreatedSub;
  bool _ready = false;
  Drop? _selectedDrop;
  bool _loadingRoute = false;
  bool _showTutorial = false;

  // Bottom sheet animation
  late AnimationController _sheetCtrl;
  late Animation<Offset> _sheetSlide;

  @override
  void initState() {
    super.initState();
    MapboxOptions.setAccessToken(dotenv.env['MAPBOX_ACCESS_TOKEN']!);

    _sheetCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _sheetSlide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _sheetCtrl, curve: Curves.easeOutCubic));

    _initLocation();
    _checkTutorial();
    _dropCreatedSub = DropEvents.instance.onDropCreated.listen((_) {
      // MapScreen may be kept alive in HomeShell's IndexedStack even
      // while another tab is visible — refetch so a newly created drop
      // shows up without waiting for a manual reload.
      if (_position != null) _loadDrops(_position!);
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _dropCreatedSub?.cancel();
    _sheetCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkTutorial() async {
    final show = await OnboardingService.instance.shouldShowMapTutorial();
    if (mounted) setState(() => _showTutorial = show);
  }

  Future<void> _initLocation() async {
    try {
      final position = await LocationService.instance.getCurrentPosition();
      setState(() => _position = position);
      await _loadDrops(position);

      _positionSub = LocationService.instance.watchPosition().listen((pos) {
        setState(() => _position = pos);
      });
    } catch (e) {
      debugPrint('Location error: $e');
    }
  }

  Future<void> _loadDrops(geo.Position position) async {
    try {
      final drops = await SupabaseService.instance.fetchNearbyDrops(
        lat: position.latitude,
        lng: position.longitude,
        radiusM: 10000,
      );
      setState(() => _drops = drops);
      if (_mapboxMap != null && _ready) await _updateDropPins();
    } catch (e) {
      debugPrint('Drops load error: $e');
    }
  }

  Future<void> _onMapCreated(MapboxMap mapboxMap) async {
    _mapboxMap = mapboxMap;

    await mapboxMap.gestures.updateSettings(
      GesturesSettings(rotateEnabled: true, pitchEnabled: false),
    );
    await mapboxMap.logo.updateSettings(LogoSettings(enabled: false));
    await mapboxMap.attribution
        .updateSettings(AttributionSettings(enabled: false));
    await mapboxMap.location.updateSettings(LocationComponentSettings(
      enabled: true,
      pulsingEnabled: true,
      pulsingColor: 0xFF7B61FF,
    ));

    setState(() => _ready = true);
    await _setupLayers();

    if (_position != null) {
      await _updateDropPins();
      await _flyToUser();
    }
  }

  Future<void> _setupLayers() async {
    final map = _mapboxMap;
    if (map == null) return;

    // Drop pins source
    await map.style.addSource(GeoJsonSource(
      id: 'drops-source',
      data: json.encode(_buildDropGeoJson([])),
    ));

    // Locked drop — muted circle
    await map.style.addLayer(CircleLayer(
      id: 'drops-locked',
      sourceId: 'drops-source',
      filter: ['==', ['get', 'unlocked'], false],
      circleRadius: 14.0,
      circleColor: 0xFF2A2A3A,
      circleStrokeWidth: 2.0,
      circleStrokeColor: 0xFF8888A8,
    ));

    // Unlocked drop — violet circle
    await map.style.addLayer(CircleLayer(
      id: 'drops-unlocked',
      sourceId: 'drops-source',
      filter: ['==', ['get', 'unlocked'], true],
      circleRadius: 14.0,
      circleColor: 0xFF7B61FF,
      circleStrokeWidth: 2.0,
      circleStrokeColor: 0xFFFFFFFF,
    ));

    // Distance label using token syntax
    await map.style.addLayer(SymbolLayer(
      id: 'drops-label',
      sourceId: 'drops-source',
      textField: '{distance_label}',
      textSize: 11.0,
      textOffset: [0.0, -2.5],
      textColor: 0xFFFFFFFF,
      textHaloColor: 0xFF0A0A0F,
      textHaloWidth: 1.5,
      textAllowOverlap: false,
    ));

    // Route source + layer
    await map.style.addSource(GeoJsonSource(
      id: 'route-source',
      data: json.encode({'type': 'FeatureCollection', 'features': []}),
    ));

    await map.style.addLayer(LineLayer(
      id: 'route-line',
      sourceId: 'route-source',
      lineColor: 0xFF7B61FF,
      lineWidth: 5.0,
      lineOpacity: 0.9,
      lineCap: LineCap.ROUND,
      lineJoin: LineJoin.ROUND,
    ));

    // Dashed overlay on route for style
    await map.style.addLayer(LineLayer(
      id: 'route-dash',
      sourceId: 'route-source',
      lineColor: 0xFFFFFFFF,
      lineWidth: 1.5,
      lineOpacity: 0.4,
      lineDasharray: [2.0, 4.0],
      lineCap: LineCap.ROUND,
    ));

    map.onMapTapListener = _handleMapTap;
  }

  Future<void> _handleMapTap(MapContentGestureContext tapCtx) async {
    final map = _mapboxMap;
    final pos = _position;
    if (map == null || pos == null) return;

    final features = await map.queryRenderedFeatures(
      RenderedQueryGeometry.fromScreenCoordinate(tapCtx.touchPosition),
      RenderedQueryOptions(layerIds: ['drops-locked', 'drops-unlocked']),
    );

    if (features.isEmpty) {
      await _clearRoute();
      _sheetCtrl.reverse();
      setState(() => _selectedDrop = null);
      return;
    }

    final rawProps = features.first?.queriedFeature.feature['properties'];
    if (rawProps == null) return;
    final props = rawProps as Map<String, Object?>;
    final dropId = props['id'] as String?;
    if (dropId == null) return;

    try {
      final drop = _drops.firstWhere((d) => d.id == dropId);
      setState(() => _selectedDrop = drop);
      _sheetCtrl.forward();
      await _drawRoute(pos, drop);
    } catch (_) {}
  }

  Future<void> _drawRoute(geo.Position from, Drop to) async {
    if (to.dropLat == null || to.dropLng == null) return;
    setState(() => _loadingRoute = true);
    try {
      final token = dotenv.env['MAPBOX_ACCESS_TOKEN']!;
      final url = Uri.parse(
        'https://api.mapbox.com/directions/v5/mapbox/walking/'
        '${from.longitude},${from.latitude};'
        '${to.dropLng},${to.dropLat}'
        '?geometries=geojson&overview=full&access_token=$token',
      );

      final response = await http.get(url);
      if (response.statusCode != 200) return;

      final data = json.decode(response.body) as Map<String, dynamic>;
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) return;

      final geometry = routes.first['geometry'] as Map<String, dynamic>;

      await _mapboxMap?.style.setStyleSourceProperty(
        'route-source',
        'data',
        json.encode({
          'type': 'FeatureCollection',
          'features': [
            {'type': 'Feature', 'geometry': geometry, 'properties': {}}
          ],
        }),
      );

      await _fitCameraToRoute(from, to);
    } catch (e) {
      debugPrint('Route error: $e');
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  Future<void> _fitCameraToRoute(geo.Position from, Drop to) async {
    final map = _mapboxMap;
    if (map == null || to.dropLat == null || to.dropLng == null) return;

    final minLat = [from.latitude, to.dropLat!].reduce((a, b) => a < b ? a : b);
    final maxLat = [from.latitude, to.dropLat!].reduce((a, b) => a > b ? a : b);
    final minLng = [from.longitude, to.dropLng!].reduce((a, b) => a < b ? a : b);
    final maxLng = [from.longitude, to.dropLng!].reduce((a, b) => a > b ? a : b);

    final camera = await map.cameraForCoordinateBounds(
      CoordinateBounds(
        southwest: Point(coordinates: Position(minLng - 0.001, minLat - 0.001)),
        northeast: Point(coordinates: Position(maxLng + 0.001, maxLat + 0.001)),
        infiniteBounds: false,
      ),
      MbxEdgeInsets(top: 80, left: 40, bottom: 220, right: 40),
      null, null, null, null,
    );
    await map.flyTo(camera, MapAnimationOptions(duration: 900));
  }

  Future<void> _clearRoute() async {
    await _mapboxMap?.style.setStyleSourceProperty(
      'route-source',
      'data',
      json.encode({'type': 'FeatureCollection', 'features': []}),
    );
  }

  Future<void> _updateDropPins() async {
    final map = _mapboxMap;
    if (map == null || !_ready) return;
    try {
      await map.style.setStyleSourceProperty(
        'drops-source',
        'data',
        json.encode(_buildDropGeoJson(_drops)),
      );
    } catch (e) {
      debugPrint('Pin update error: $e');
    }
  }

  Map<String, dynamic> _buildDropGeoJson(List<Drop> drops) {
    return {
      'type': 'FeatureCollection',
      'features': drops
          .where((d) => d.dropLat != null && d.dropLng != null)
          .map((d) => {
                'type': 'Feature',
                'geometry': {
                  'type': 'Point',
                  // GeoJSON = [longitude, latitude] — accurate real coords
                  'coordinates': [d.dropLng!, d.dropLat!],
                },
                'properties': {
                  'id': d.id,
                  'unlocked': d.isUnlocked,
                  'distance_label': d.distanceLabel,
                  'distance_m': d.distanceM,
                },
              })
          .toList(),
    };
  }

  Future<void> _flyToUser() async {
    final pos = _position;
    if (_mapboxMap == null || pos == null) return;
    await _mapboxMap!.flyTo(
      CameraOptions(
        center: Point(coordinates: Position(pos.longitude, pos.latitude)),
        zoom: 15.5,
      ),
      MapAnimationOptions(duration: 1200),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return Stack(
      children: [
        Scaffold(
          body: Stack(
            children: [
              // Satellite Streets map
              MapWidget(
                onMapCreated: _onMapCreated,
                styleUri: MapboxStyles.SATELLITE_STREETS,
                cameraOptions: CameraOptions(
                  center: Point(
                    coordinates: Position(
                      _position?.longitude ?? 36.8219,
                      _position?.latitude ?? -1.2921,
                    ),
                  ),
                  zoom: 14.0,
                ),
              ),

              // Top badge
              Positioned(
                top: MediaQuery.of(context).padding.top + 12,
                left: 16,
                child: AnimatedOpacity(
                  opacity: _drops.isEmpty ? 0 : 1,
                  duration: const Duration(milliseconds: 400),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: RMColors.surface.withOpacity(0.92),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: RMColors.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: RMColors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${_drops.length} drops nearby',
                          style: const TextStyle(
                              color: RMColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Route loading
              if (_loadingRoute)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 12,
                  right: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: RMColors.surface.withOpacity(0.92),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: RMColors.border),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 12,
                          width: 12,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: RMColors.primary),
                        ),
                        SizedBox(width: 6),
                        Text('Routing…',
                            style: TextStyle(
                                color: RMColors.textSecondary,
                                fontSize: 12)),
                      ],
                    ),
                  ),
                ),

              // Re-center button
              Positioned(
                bottom: _selectedDrop != null ? 200 : 100,
                right: 16,
                child: _MapButton(
                  icon: Icons.my_location_rounded,
                  onTap: _flyToUser,
                ),
              ),

              // Selected drop bottom sheet
              if (_selectedDrop != null)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: SlideTransition(
                    position: _sheetSlide,
                    child: _DropSheet(
                      drop: _selectedDrop!,
                      loadingRoute: _loadingRoute,
                      onClose: () async {
                        await _clearRoute();
                        _sheetCtrl.reverse();
                        setState(() => _selectedDrop = null);
                      },
                      onOpen: _position == null
                          ? null
                          : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => DropDetailScreen(
                                    drop: _selectedDrop!,
                                    currentLat: _position!.latitude,
                                    currentLng: _position!.longitude,
                                  ),
                                ),
                              ),
                      onRoute: _position == null || _loadingRoute
                          ? null
                          : () => _drawRoute(_position!, _selectedDrop!),
                      bottomPad: bottomPad,
                    ),
                  ),
                ),
            ],
          ),
        ),

        // Map tutorial
        if (_showTutorial)
          TutorialOverlay(
            steps: const [
              TutorialStep(
                icon: Icons.satellite_alt_rounded,
                title: 'Live satellite map',
                body: 'You\'re looking at real satellite imagery. Purple pins are unlocked drops, grey pins are locked ones waiting for you to walk to them.',
              ),
              TutorialStep(
                icon: Icons.touch_app_rounded,
                title: 'Tap any pin',
                body: 'Tap a drop pin to see its distance and get walking directions. The route draws right on the satellite map.',
              ),
              TutorialStep(
                icon: Icons.directions_walk_rounded,
                title: 'Walk to unlock',
                body: 'Follow the route, get within the unlock radius, and tap "Open drop" to reveal what\'s hidden there.',
              ),
            ],
            onDone: () async {
              await OnboardingService.instance.markMapTutorialSeen();
              if (mounted) setState(() => _showTutorial = false);
            },
          ),
      ],
    );
  }
}

class _MapButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _MapButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: RMColors.surface.withOpacity(0.95),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: RMColors.border),
        ),
        child: Icon(icon, color: RMColors.textPrimary, size: 20),
      ),
    );
  }
}

class _DropSheet extends StatelessWidget {
  final Drop drop;
  final bool loadingRoute;
  final VoidCallback onClose;
  final VoidCallback? onOpen;
  final VoidCallback? onRoute;
  final double bottomPad;

  const _DropSheet({
    required this.drop,
    required this.loadingRoute,
    required this.onClose,
    required this.onOpen,
    required this.onRoute,
    required this.bottomPad,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: RMColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: const Border(top: BorderSide(color: RMColors.border)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 24,
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, bottomPad + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: RMColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: drop.isUnlocked
                      ? RMColors.success.withOpacity(0.1)
                      : RMColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  drop.isUnlocked
                      ? Icons.lock_open_rounded
                      : Icons.lock_rounded,
                  color: drop.isUnlocked ? RMColors.success : RMColors.textHint,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      drop.isUnlocked
                          ? (drop.caption ?? 'Drop')
                          : 'Locked drop',
                      style: const TextStyle(
                        color: RMColors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${drop.distanceLabel}  ·  by ${drop.creatorUsername}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: onClose,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: RMColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.close_rounded,
                      color: RMColors.textSecondary, size: 16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: onOpen,
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('Open drop'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 46),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onRoute,
                  icon: loadingRoute
                      ? const SizedBox(
                          height: 14,
                          width: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: RMColors.primary),
                        )
                      : const Icon(Icons.alt_route_rounded, size: 16),
                  label: const Text('Route'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 46),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
