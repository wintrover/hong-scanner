import 'package:flutter/material.dart';

import '../state/app_store.dart';

/// Loading state: distinct from "no record" — a fetch is in flight.
class SectionSkeleton extends StatelessWidget {
  const SectionSkeleton({super.key, this.label = '기록을 읽는 중…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 12),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Honest absence: the API answered but recorded nothing here. Rendered
/// differently from both loading and error — never as success-with-data.
class SectionEmpty extends StatelessWidget {
  const SectionEmpty({super.key, this.message = '기록 없음'});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Row(
        children: [
          Icon(Icons.inventory_2_outlined,
              size: 18, color: Theme.of(context).disabledColor),
          const SizedBox(width: 8),
          Text(message,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Theme.of(context).disabledColor)),
        ],
      ),
    );
  }
}

/// Error state: connectivity failures say offline explicitly; server
/// refusals carry their recorded code. Optional retry.
class SectionErrorCard extends StatelessWidget {
  const SectionErrorCard({
    super.key,
    required this.message,
    required this.offline,
    this.onRetry,
  });

  final String message;
  final bool offline;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  offline ? Icons.cloud_off : Icons.error_outline,
                  size: 18,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  offline ? '오프라인' : '오류',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(message, style: Theme.of(context).textTheme.bodySmall),
            if (onRetry != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('다시 시도'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A section body that switches on the store's load phase. [loaded] may
/// receive a null value — the API's honest "no record" — which renders as
/// [SectionEmpty].
Widget sectionBody<T>(
  BuildContext context,
  Section<T> section, {
  Widget Function(BuildContext, T)? loaded,
  String? emptyMessage,
  VoidCallback? onRetry,
}) {
  return switch (section.phase) {
    LoadPhase.idle ||
    LoadPhase.loading =>
      const SectionSkeleton(),
    LoadPhase.error => SectionErrorCard(
        message: section.errorMessage ?? '알 수 없는 오류',
        offline: section.offline,
        onRetry: onRetry,
      ),
    LoadPhase.loaded => section.value == null
        ? SectionEmpty(message: emptyMessage ?? '기록 없음')
        : loaded?.call(context, section.value as T) ?? const SizedBox.shrink(),
  };
}

/// Recorded fact rows: label + value lines for what the API actually
/// serves. Values are verbatim strings — no reformatting into something
/// they are not.
class FactRows extends StatelessWidget {
  const FactRows({super.key, required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 116,
                  child: Text(label,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                Expanded(
                  child: SelectableText(value,
                      style: Theme.of(context).textTheme.bodyMedium),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Section card header.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (subtitle != null)
            Text(subtitle!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).hintColor)),
        ],
      ),
    );
  }
}
