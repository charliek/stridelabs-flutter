import 'relay_channel.dart';

/// No `dart:io` (web): the relay cannot be reached.
Future<RelayChannel> connectRelay(
  Uri uri, {
  required Map<String, String> headers,
}) async => throw const RelayUpgradeException(null);
