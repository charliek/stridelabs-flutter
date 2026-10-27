import 'dart:typed_data';

/// [length] bytes of "speech": every byte [value] (never silence).
Uint8List speech(int length, {int value = 1}) =>
    Uint8List(length)..fillRange(0, length, value);
