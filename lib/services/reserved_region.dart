// reserved_region.dart — the iPhone Duo's status/camera bubble, as reported by
// the iOS host (RunnerViewController, channel "posta/reserved_regions").
//
// The host already moves the safe area's top edge below the bubble; this tells
// the app where exactly the bubble is, so the shell can use the space beside it
// (top bar + a large page title) instead of leaving it empty. null everywhere
// else (other phones, iPads, Mac, Windows, Android).

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class ReservedTopRegion {
  /// The bubble, margins included, in logical pixels of the app's screen.
  final Rect rect;

  /// The system's own top inset, without the bubble.
  final double systemTop;

  const ReservedTopRegion(this.rect, this.systemTop);

  static ReservedTopRegion? fromMap(Object? m) {
    if (m is! Map) return null;
    double n(String k) => (m[k] as num?)?.toDouble() ?? 0;
    final r = Rect.fromLTRB(n('left'), n('top'), n('right'), n('bottom'));
    if (r.isEmpty) return null;
    // The bubble holds the status bar, so it starts above the system's top
    // inset; anything lower (a floating call window) is not it.
    final top = n('systemTop');
    if (top > 0 && r.top >= top) return null;
    return ReservedTopRegion(r, top);
  }

  @override
  bool operator ==(Object other) => other is ReservedTopRegion && other.rect == rect && other.systemTop == systemTop;

  @override
  int get hashCode => Object.hash(rect, systemTop);
}

class ReservedRegions extends ValueNotifier<ReservedTopRegion?> {
  ReservedRegions._() : super(null);

  static final ReservedRegions instance = ReservedRegions._();
  static const _channel = MethodChannel('posta/reserved_regions');
  bool _started = false;

  /// Starts listening (iOS only; harmless elsewhere).
  void start() {
    if (_started || kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') value = ReservedTopRegion.fromMap(call.arguments);
    });
    _channel.invokeMethod<Object?>('current').then((v) => value = ReservedTopRegion.fromMap(v), onError: (_) {});
  }
}
