import 'package:flutter/material.dart';

import 'package:voyza/services/email_history_service.dart';

/// Drop-in list of previously-used emails, shown directly under an email
/// field while that field has focus.
///
/// Rendered inline (not in an Overlay) on purpose: the auth forms live in a
/// scroll view that moves when the keyboard opens, and an overlay would have
/// to chase the field's position. Inline just moves with it.
///
/// Appears the moment the field is focused — with no text yet, every stored
/// address is offered — and narrows as the user types.
class EmailSuggestions extends StatelessWidget {
  const EmailSuggestions({
    super.key,
    required this.visible,
    required this.query,
    required this.onSelected,
    required this.onForget,
  });

  /// Usually `focusNode.hasFocus`.
  final bool visible;

  /// Current field text — filters the list.
  final String query;

  final ValueChanged<String> onSelected;
  final ValueChanged<String> onForget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches =
        visible ? EmailHistoryService.instance.suggestionsFor(query) : const [];

    return AnimatedSize(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: matches.isEmpty
          ? const SizedBox(width: double.infinity)
          : Container(
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < matches.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.08),
                      ),
                    InkWell(
                      onTap: () => onSelected(matches[i]),
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(i == 0 ? 12 : 0),
                        bottom:
                            Radius.circular(i == matches.length - 1 ? 12 : 0),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                        child: Row(
                          children: [
                            Icon(Icons.history_rounded,
                                size: 18,
                                color: theme.colorScheme.onSurfaceVariant),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                matches[i],
                                style: theme.textTheme.bodyMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close_rounded, size: 16),
                              tooltip: 'Remove from suggestions',
                              visualDensity: VisualDensity.compact,
                              color: theme.colorScheme.onSurfaceVariant,
                              onPressed: () => onForget(matches[i]),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
