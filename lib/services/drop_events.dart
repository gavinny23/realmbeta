import 'dart:async';

/// A minimal broadcast bus for "a drop was just created" — any screen
/// that fetched its own drops once (and isn't already refetching after
/// its own create flow) can subscribe in initState and refetch when it
/// fires.
class DropEvents {
  DropEvents._();
  static final DropEvents instance = DropEvents._();

  final _controller = StreamController<void>.broadcast();

  Stream<void> get onDropCreated => _controller.stream;

  void notifyDropCreated() => _controller.add(null);

  void dispose() => _controller.close();
}
