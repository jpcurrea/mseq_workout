import 'dart:math';
import 'package:flutter/material.dart';

/// Urgency color for a task based on its [startBy] time and [durationMinutes].
///
/// **Pre-deadline** (time_remaining > 0):
///   Hue interpolates 120°→0° (green→red) as urgency increases.
///   Saturation is fixed at 50% (visually desaturated).
///
/// **At deadline** (time_remaining == 0):
///   Full red, 50% saturation.
///
/// **Post-deadline** (time_remaining < 0):
///   Hue stays red (0°).
///   Saturation = 0.8 − 0.3 × exp(−2 × overdue / duration)
///     → 50% at overdue=0, asymptotes to 80%, reaches ~79.9% at overdue=3×duration.
///
/// **No deadline**: neutral grey.
Color urgencyColor(DateTime? startBy, int? durationMinutes) {
  if (startBy == null) {
    return HSLColor.fromAHSL(1.0, 0, 0, 0.62).toColor();
  }

  final now = DateTime.now();
  final timeRemainingSeconds = startBy.difference(now).inSeconds.toDouble();
  final timeRemainingMinutes = timeRemainingSeconds / 60.0;

  if (timeRemainingMinutes > 0) {
    // Pre-deadline: desaturated green→yellow→red
    const horizonMinutes = 7 * 24 * 60.0;
    final urgency = 1.0 - min(timeRemainingMinutes / horizonMinutes, 1.0);
    final hue = 120.0 * (1.0 - urgency); // 120=green, 60=yellow, 0=red
    return HSLColor.fromAHSL(1.0, hue, 0.50, 0.50).toColor();
  } else {
    // Post-deadline: red with asymptotically increasing saturation
    final overdueMinutes = -timeRemainingMinutes;
    final d = max((durationMinutes ?? 60).toDouble(), 1.0);
    final saturation = 0.8 - 0.3 * exp(-2.0 * overdueMinutes / d);
    return HSLColor.fromAHSL(1.0, 0.0, saturation, 0.46).toColor();
  }
}

/// Urgency color from a pre-computed [urgencyScore] in [0, 1] and whether
/// the task is already overdue. Used when displaying the score from the API
/// without recomputing time locally.
Color urgencyColorFromScore(double score, {bool overdue = false, int? durationMinutes}) {
  if (!overdue && score <= 0) {
    return HSLColor.fromAHSL(1.0, 0, 0, 0.62).toColor();
  }
  if (!overdue) {
    final hue = 120.0 * (1.0 - score);
    return HSLColor.fromAHSL(1.0, hue, 0.50, 0.50).toColor();
  }
  // Overdue — saturation based on urgency score as proxy for time-overdue ratio
  final saturation = 0.5 + 0.3 * score;
  return HSLColor.fromAHSL(1.0, 0.0, saturation.clamp(0.5, 0.8), 0.46).toColor();
}
