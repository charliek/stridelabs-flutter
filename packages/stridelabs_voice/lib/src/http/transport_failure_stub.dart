/// No `dart:io` (web): an unclassified failure is never taken for a lost
/// connection there (the browser reports one as a connection error).
bool isConnectionLost(Object? cause) => false;
