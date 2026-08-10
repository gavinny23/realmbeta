import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:sensors_plus/sensors_plus.dart';
import '../models/drop.dart';
import '../services/location_service.dart';
import '../services/supabase_service.dart';
import '../services/local_cache_service.dart';
import '../theme/rm_theme.dart';
import '../widgets/drop_card.dart';
import 'drop_detail_screen.dart';

/// A magnetometer-based compass that also points toward — and lists —
/// nearby locked drops, so it can stand in for "walk this way" guidance
/// now that the dedicated AR/Map tabs are gone. Cards below the rose use
/// the same [DropCard] component as the Explore feed, so a drop looks
/// and behaves identically in either tab (same location badge, same
/// unlock affordance, same photo/video thumbnail handling).
class CompassScreen extends StatefulWidget {
  const CompassScreen({super.key});

  @override
  State<CompassScreen> createState() => CompassScreenState();
}

class CompassScreenState extends State<CompassScreen> {
  // Same key the Explore feed uses (see feed_screen.dart) — both
  // screens are just different views over "drops near me", so
  // whichever one refreshes first also warms the other's cache.
  static const _cacheKey = 'nearby_drops';

  StreamSubscription<MagnetometerEvent>? _compassSub;
  StreamSubscription<geo.Position>? _positionSub;
  double _heading = 0;
  geo.Position? _position;
  // Every drop within range — locked or already-unlocked — so this tab
  // never contradicts what Explore/Map show as "nearby". Previously this
  // only kept the locked subset, which meant the compass could report
  // "nothing nearby" even while drops clearly existed in range (they'd
  // just already been unlocked, or were the user's own).
  List<Drop> _nearby = [];
  bool _loading = true;
  bool _offline = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _compassSub = magnetometerEventStream().listen((event) {
      final heading = math.atan2(event.y, event.x) * (180 / math.pi);
      if (mounted) setState(() => _heading = (heading + 360) % 360);
    });
    _loadCachedNearby();
    _init();
  }

  /// Shows whatever was cached last time immediately, before location
  /// has even been acquired.
  Future<void> _loadCachedNearby() async {
    final cached = await LocalCacheService.instance.loadList(_cacheKey);
    if (cached != null && cached.isNotEmpty && mounted && _nearby.isEmpty) {
      setState(() {
        _nearby = cached.map(Drop.fromMap).toList();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _compassSub?.cancel();
    _positionSub?.cancel();
    super.dispose();
  }

  /// Called on first load, on pull-to-refresh, and by [HomeShell] every
  /// time this tab is selected (including switching back to it). Doing
  /// the fetch again on every visit — rather than relying solely on the
  /// initial `initState` call plus the position stream — means a failed
  /// first attempt (permission dialog still pending, no signal yet,
  /// cold-start race with auth) doesn't leave the tab permanently empty
  /// for the rest of the session.
  Future<void> refresh() => _init();

  Future<void> _init() async {
    if (_nearby.isEmpty) setState(() { _loading = true; _error = null; });
    try {
      // Reuse an already-running position stream rather than starting a
      // second one on every refresh.
      final position = _position ??
          await LocationService.instance.getCurrentPosition();
      if (mounted) setState(() => _position = position);
      await _fetchNearby(position);

      _positionSub ??= LocationService.instance.watchPosition().listen((pos) {
        if (mounted) setState(() => _position = pos);
        _fetchNearby(pos);
      });
    } catch (e) {
      if (mounted) {
        if (_nearby.isNotEmpty) {
          setState(() => _offline = true);
        } else {
          setState(() => _error = e.toString());
        }
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _fetchNearby(geo.Position position) async {
    try {
      final drops = await SupabaseService.instance.fetchNearbyDrops(
        lat: position.latitude,
        lng: position.longitude,
      );
      if (mounted) {
        setState(() { _nearby = drops; _offline = false; });
      }
      await LocalCacheService.instance
          .saveList(_cacheKey, drops.map((d) => d.toMap()).toList());
    } catch (e) {
      // Keep whatever's already on screen — cached or previously
      // fetched — rather than blanking it out over one failed refresh.
      if (mounted) {
        if (_nearby.isNotEmpty) {
          setState(() => _offline = true);
        } else {
          setState(() => _error = e.toString());
        }
      }
    }
  }

  Future<void> _openDrop(Drop drop) async {
    if (_position == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DropDetailScreen(
          drop: drop,
          currentLat: _position!.latitude,
          currentLng: _position!.longitude,
        ),
      ),
    );
    if (_position != null) await _fetchNearby(_position!);
  }

  /// Bearing from the current position to a target lat/lng, in degrees
  /// from true north — the classic great-circle initial bearing formula.
  double _bearingTo(double lat1, double lng1, double lat2, double lng2) {
    final phi1 = lat1 * math.pi / 180;
    final phi2 = lat2 * math.pi / 180;
    final deltaLambda = (lng2 - lng1) * math.pi / 180;
    final y = math.sin(deltaLambda) * math.cos(phi2);
    final x = math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(deltaLambda);
    final theta = math.atan2(y, x);
    return (theta * 180 / math.pi + 360) % 360;
  }

  Drop? get _nearestLocked {
    if (_nearby.isEmpty) return null;
    for (final d in _nearby) {
      if (!d.isUnlocked) return d;
    }
    // Everything nearby is already unlocked — still point at the
    // closest one rather than showing no needle at all.
    return _nearby.first;
  }

  @override
  Widget build(BuildContext context) {
    final target = _nearestLocked;
    double? targetBearing;
    if (target != null &&
        _position != null &&
        target.dropLat != null &&
        target.dropLng != null) {
      targetBearing = _bearingTo(
        _position!.latitude,
        _position!.longitude,
        target.dropLat!,
        target.dropLng!,
      );
    }

    return Scaffold(
      backgroundColor: RMColors.background,
      appBar: AppBar(
        backgroundColor: RMColors.background,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Private Drops'),
            if (!_loading && (_position != null || (_offline && _nearby.isNotEmpty)))
              Text(
                _offline
                    ? '${_nearby.length} drops nearby · offline, showing saved posts'
                    : '${_nearby.length} drops nearby',
                style: Theme.of(context).textTheme.labelSmall,
              ),
          ],
        ),
      ),
      body: _loading
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: RMColors.primary),
                  SizedBox(height: 16),
                  Text('Finding your location…',
                      style: TextStyle(color: RMColors.textSecondary)),
                ],
              ),
            )
          : SafeArea(
              child: Column(
                children: [
                  if (_error != null)
                    Padding(
                      padding: EdgeInsets.fromLTRB(20, 20, 20, 0),
                      child: Column(
                        children: [
                          Text(_error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: RMColors.textSecondary)),
                          SizedBox(height: 12),
                          OutlinedButton(
                              onPressed: refresh, child: Text('Try again')),
                        ],
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(24, 20, 24, 8),
                    child: _CompassRose(
                      heading: _heading,
                      targetBearing: targetBearing,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
                    child: target == null
                        ? Text(
                            'No drops nearby right now.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: RMColors.textSecondary),
                          )
                        : Text(
                            target.isUnlocked
                                ? 'Nearest drop · ${target.distanceLabel}'
                                : 'Nearest locked drop · ${target.distanceLabel}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: RMColors.primary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                  Divider(color: RMColors.border, height: 1),
                  Expanded(
                    child: RefreshIndicator(
                      color: RMColors.primary,
                      backgroundColor: RMColors.surface,
                      onRefresh: refresh,
                      child: _buildList(),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildList() {
    if (_nearby.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.explore_off_rounded,
                      color: RMColors.textHint, size: 48),
                  SizedBox(height: 12),
                  Text('Nothing nearby yet.',
                      style: TextStyle(
                          color: RMColors.textPrimary,
                          fontWeight: FontWeight.w600)),
                  SizedBox(height: 4),
                  Text('Pull down to check again.',
                      style: TextStyle(color: RMColors.textSecondary)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      physics: AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _nearby.length,
      itemBuilder: (context, index) => AnimatedDropCard(
        key: ValueKey(_nearby[index].id),
        drop: _nearby[index],
        index: index,
        onTap: () => _openDrop(_nearby[index]),
      ),
    );
  }
}

/// The rose itself: a fixed amber "you" arrow at the top, a rotating
/// dial of cardinal directions, and — if a target bearing is known — a
/// violet needle pointing toward the nearest locked drop.
class _CompassRose extends StatelessWidget {
  final double heading;
  final double? targetBearing;

  const _CompassRose({required this.heading, this.targetBearing});

  @override
  Widget build(BuildContext context) {
    const size = 180.0;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: RMColors.surface,
              border: Border.all(color: RMColors.border, width: 1.5),
            ),
          ),
          // Rotating dial with N/E/S/W — rotates opposite the heading
          // so the labeled direction always faces the way it actually is.
          Transform.rotate(
            angle: -heading * math.pi / 180,
            child: SizedBox(
              width: size,
              height: size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _cardinal('N', 0, size, RMColors.textPrimary),
                  _cardinal('E', 90, size, RMColors.textSecondary),
                  _cardinal('S', 180, size, RMColors.textSecondary),
                  _cardinal('W', 270, size, RMColors.textSecondary),
                  if (targetBearing != null)
                    Transform.rotate(
                      angle: targetBearing! * math.pi / 180,
                      child: Align(
                        alignment: Alignment(0, -0.62),
                        child: Icon(Icons.navigation_rounded,
                            color: RMColors.primary, size: 26),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Fixed "you are here" pointer — always points up (device-forward).
          Icon(Icons.navigation_rounded, color: RMColors.accent, size: 20),
        ],
      ),
    );
  }

  Widget _cardinal(String label, double angleDeg, double size, Color color) {
    return Transform.rotate(
      angle: angleDeg * math.pi / 180,
      child: Align(
        alignment: Alignment(0, -0.86),
        child: Transform.rotate(
          angle: -angleDeg * math.pi / 180,
          child: Text(
            label,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w800, fontSize: 14),
          ),
        ),
      ),
    );
  }
}
