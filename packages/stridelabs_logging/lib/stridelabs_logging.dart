/// Namespaced app logging for StrideLabs Flutter apps.
///
/// A thin `debugPrint` wrapper ([log]) that prefixes each line with a subsystem
/// tag (`[area] message`), plus a single crash-sink seam ([logSink]) a
/// crash-reporting backend can fan out from without touching call sites.
library;

export 'src/log.dart';
