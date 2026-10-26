import 'dart:io';

/// The socket failed under the request: a reset (`SocketException`), or the
/// connection closed before the whole response arrived (`HttpException`).
bool isConnectionLost(Object? cause) =>
    cause is SocketException || cause is HttpException;
