import 'dart:async';
import 'dart:io';

/// Polls internet reachability by attempting a socket connection.
class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._();
  factory ConnectivityService() => _instance;
  ConnectivityService._();

  bool _online = true;
  bool get isOnline => _online;

  final _controller = StreamController<bool>.broadcast();
  Stream<bool> get onStatusChange => _controller.stream;

  Timer? _timer;

  void startMonitoring({Duration interval = const Duration(seconds: 15)}) {
    _timer?.cancel();
    _check(); // immediate first check
    _timer = Timer.periodic(interval, (_) => _check());
  }

  void stopMonitoring() {
    _timer?.cancel();
    _controller.close();
  }

  Future<bool> _check() async {
    bool reachable;
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 5));
      reachable = result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } on SocketException {
      reachable = false;
    } on TimeoutException {
      reachable = false;
    }
    if (reachable != _online) {
      _online = reachable;
      _controller.add(_online);
    }
    return _online;
  }

  Future<bool> checkNow() => _check();
}
