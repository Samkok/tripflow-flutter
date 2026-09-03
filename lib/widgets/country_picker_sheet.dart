import 'package:flutter/material.dart';
import '../utils/countries.dart';
import 'country_flag_icon.dart';

/// Bottom-sheet country picker. Returns the selected [Country] via
/// `Navigator.pop`, or `null` if the user cancels. Tapping "Clear" returns
/// the sentinel [kClearCountry] so the caller can distinguish "leave
/// unchanged" (null) from "explicitly clear" (sentinel).
const Country kClearCountry = Country('--', '__clear__');

Future<Country?> showCountryPickerSheet(
  BuildContext context, {
  String? selectedCode,
}) {
  return showModalBottomSheet<Country>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CountryPickerSheet(selectedCode: selectedCode),
  );
}

class _CountryPickerSheet extends StatefulWidget {
  final String? selectedCode;

  const _CountryPickerSheet({this.selectedCode});

  @override
  State<_CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<_CountryPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Country> get _filtered {
    if (_query.isEmpty) return kCountries;
    // Folded matching: diacritic-insensitive + aliases, so "turkey" finds
    // "Türkiye" and "ivory coast" finds "Côte d'Ivoire".
    final q = foldForSearch(_query);
    return kCountries.where((c) => c.matchesQuery(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.selectedCode?.toUpperCase();

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Select Country',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (selected != null)
                      TextButton.icon(
                        onPressed: () =>
                            Navigator.of(context).pop(kClearCountry),
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: const Text('Clear'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  cursorOpacityAnimates: false,
                  controller: _searchController,
                  onChanged: (v) => setState(() => _query = v.trim()),
                  autofocus: false,
                  decoration: InputDecoration(
                    hintText: 'Search countries…',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _filtered.isEmpty
                    ? Center(
                        child: Text(
                          'No countries match "$_query"',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.textTheme.bodyMedium?.color
                                ?.withValues(alpha: 0.6),
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: _filtered.length,
                        itemBuilder: (context, index) {
                          final country = _filtered[index];
                          final isSelected = country.code == selected;
                          return ListTile(
                            leading: CountryFlagIcon(country.code, height: 22),
                            title: Text(country.name),
                            subtitle: Text(country.code),
                            trailing: isSelected
                                ? Icon(
                                    Icons.check_circle_rounded,
                                    color: theme.colorScheme.primary,
                                  )
                                : null,
                            onTap: () => Navigator.of(context).pop(country),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
