import 'package:flutter/material.dart';

/// Returns a left-truncated version of [text] that fits within [maxWidth]
/// using the given [style]. Prepends "..." when truncated.
String truncateLeft(String text, double maxWidth, TextStyle style) {
  if (text.isEmpty || maxWidth <= 0) return text;

  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    maxLines: 1,
    text: TextSpan(text: text, style: style),
  );
  painter.layout(maxWidth: double.infinity);
  if (painter.width <= maxWidth) return text;

  const ellipsis = '...';
  final ellipsisPainter = TextPainter(
    textDirection: TextDirection.ltr,
    maxLines: 1,
    text: TextSpan(text: ellipsis, style: style),
  );
  ellipsisPainter.layout(maxWidth: double.infinity);
  final available = maxWidth - ellipsisPainter.width;
  if (available <= 0) return ellipsis;

  // Binary-search the longest suffix that fits within [available] width
  int lo = 0, hi = text.length;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    final candidate = text.substring(text.length - mid);
    final p = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: 1,
      text: TextSpan(text: candidate, style: style),
    );
    p.layout(maxWidth: double.infinity);
    if (p.width <= available) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }

  if (lo == 0) return ellipsis;
  return '$ellipsis${text.substring(text.length - lo)}';
}
