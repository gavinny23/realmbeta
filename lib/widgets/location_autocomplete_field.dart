import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// A place result from Nominatim structured as country / county / subcounty
class PlaceResult {
  final String displayLine1; // e.g. "Nairobi"
  final String displayLine2; // e.g. "Nairobi County, Kenya"
  final String fullText;     // what gets stored in the profile

  PlaceResult({
    required this.displayLine1,
    required this.displayLine2,
    required this.fullText,
  });

  factory PlaceResult.fromNominatim(Map<String, dynamic> json) {
    final address = json['address'] as Map<String, dynamic>? ?? {};

    // Most specific name first
    final city = address['city']
        ?? address['town']
        ?? address['municipality']
        ?? address['village']
        ?? address['suburb']
        ?? address['neighbourhood']
        ?? '';

    final subcounty = address['suburb']
        ?? address['neighbourhood']
        ?? address['quarter']
        ?? '';

    final county = address['county']
        ?? address['state_district']
        ?? address['state']
        ?? '';

    final country = address['country'] ?? 'Kenya';

    // Line 1: the city/town name — what the user typed
    final line1 = city.isNotEmpty
        ? city
        : (json['display_name'] as String).split(',').first.trim();

    // Line 2: subcounty (if different from line1), county, country
    final line2parts = <String>[];
    if (subcounty.isNotEmpty && subcounty != line1) line2parts.add(subcounty);
    if (county.isNotEmpty && county != line1) line2parts.add(county);
    if (country.isNotEmpty) line2parts.add(country);
    final line2 = line2parts.join(', ');

    // Full stored value e.g. "Kisumu, Kisumu County, Kenya"
    final allParts = <String>[line1];
    if (county.isNotEmpty && county != line1) allParts.add(county);
    if (country.isNotEmpty) allParts.add(country);
    final full = allParts.join(', ');

    return PlaceResult(
      displayLine1: line1,
      displayLine2: line2,
      fullText: full,
    );
  }
}

class LocationAutocompleteField extends StatefulWidget {
  final String label;
  final ValueChanged<String> onSelected;
  final String? initialValue;

  LocationAutocompleteField({
    super.key,
    required this.label,
    required this.onSelected,
    this.initialValue,
  });

  @override
  State<LocationAutocompleteField> createState() =>
      _LocationAutocompleteFieldState();
}

class _LocationAutocompleteFieldState
    extends State<LocationAutocompleteField> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  List<PlaceResult> _results = [];
  bool _loading = false;
  bool _showDropdown = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (widget.initialValue != null) {
      _ctrl.text = widget.initialValue!;
    }
    _focus.addListener(() {
      if (!_focus.hasFocus) {
        setState(() => _showDropdown = false);
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.length < 2) {
      setState(() {
        _results = [];
        _showDropdown = false;
      });
      return;
    }

    setState(() => _loading = true);

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?q=${Uri.encodeComponent(query)}'
        '&format=json'
        '&addressdetails=1'
        '&limit=7'
        '&accept-language=en'
        '&featuretype=settlement',
      );

      final response = await http.get(uri, headers: {
        // Nominatim requires a User-Agent identifying your app
        'User-Agent': 'RealityMerge/1.0',
      });

      if (response.statusCode == 200) {
        final List data = json.decode(response.body);
        final results = data
            .map((item) =>
                PlaceResult.fromNominatim(item as Map<String, dynamic>))
            .where((r) => r.displayLine1.isNotEmpty)
            .toList();

        // Deduplicate by fullText
        final seen = <String>{};
        final unique = results.where((r) => seen.add(r.fullText)).toList();

        setState(() {
          _results = unique;
          _showDropdown = unique.isNotEmpty;
        });
      }
    } catch (_) {
      // Silently fail — user can still type manually
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    // Wait 400ms after the user stops typing before hitting the API
    _debounce = Timer(Duration(milliseconds: 400), () {
      _search(value);
    });
  }

  void _select(PlaceResult result) {
    _ctrl.text = result.fullText;
    _focus.unfocus();
    setState(() => _showDropdown = false);
    widget.onSelected(result.fullText);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ctrl,
          focusNode: _focus,
          decoration: InputDecoration(
            labelText: widget.label,
            suffixIcon: _loading
                ? Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
          onChanged: _onChanged,
        ),
        if (_showDropdown)
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border.all(
                color: Theme.of(context).colorScheme.outline.withOpacity(0.3),
              ),
              borderRadius: BorderRadius.vertical(
                bottom: Radius.circular(8),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 8,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              itemCount: _results.length,
              separatorBuilder: (_, __) => Divider(
                height: 1,
                color: Theme.of(context).colorScheme.outline.withOpacity(0.2),
              ),
              itemBuilder: (context, index) {
                final result = _results[index];
                return InkWell(
                  onTap: () => _select(result),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.location_on_outlined, size: 18),
                        SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                result.displayLine1,
                                style: TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (result.displayLine2.isNotEmpty)
                                Text(
                                  result.displayLine2,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: Colors.grey),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
