import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:paladinvpn/logic/app_config.dart';
import 'package:paladinvpn/logic/vpn_connection.dart';
import 'package:paladinvpn/logic/crypto_service.dart';
import 'package:paladinvpn/components/notification.dart';

/// SessionTimer is the client-side session authority for the VPN tunnel.
///
/// Polls the Hivemind API to sync remaining time, data quotas, speed, and
/// throttling status.  Rather than guessing the session length optimistically,
/// it waits for the first successful sync before the local countdown begins.
class SessionTimer extends ChangeNotifier {
  Timer? _timer;
  int _tickCount = 0;

  final VpnConnection vpnConnection;

  // ── Session State ──────────────────────────────────────────────────────────
  int _remainingSeconds = 0;
  int _quotaBytes      = 0;
  int _usedBytes       = 0;
  bool _isThrottled    = false;

  // ── Sync / Network Health ──────────────────────────────────────────────────
  bool _hasSyncedOnce       = false;
  int  _consecutiveFailures = 0;
  bool _isDisconnecting     = false;
  bool _userInitiatedStop   = false;  // true when user tapped disconnect

  /// Maximum consecutive sync failures before the local countdown is paused
  /// to avoid showing a false "expired" state while the network is down.
  static const int _maxConsecutiveFailures = 3;

  /// How long we tolerate total silence from the server before forcibly
  /// killing the VPN.  Prevents the "orphaned tunnel" scenario where the
  /// server is gone but the VPN stays up forever.
  static const int _maxOfflineSeconds = 120;
  int _offlineSeconds = 0;

  /// Seconds between server polls (reduced from 3 to ease server load).
  static const int _pollIntervalSeconds = 5;

  // ── Speed State ────────────────────────────────────────────────────────────
  int    _lastUsedBytes     = 0;
  double _currentSpeedKBps  = 0.0;  // kilobytes per second

  // ── Notification dedup ─────────────────────────────────────────────────────
  String _lastNotifTime  = '';
  String _lastNotifSpeed = '';

  SessionTimer({required this.vpnConnection}) {
    vpnConnection.addListener(_onVpnConnectionChanged);
  }

  // ── Public Getters ─────────────────────────────────────────────────────────

  int  get remaining        => _remainingSeconds;
  bool get isRunning        => _timer != null && _timer!.isActive;
  bool get isExpired        => _remainingSeconds <= 0 && !isRunning;
  bool get hasSyncedOnce    => _hasSyncedOnce;

  int    get quotaBytes     => _quotaBytes;
  int    get usedBytes      => _usedBytes;
  int    get remainingBytes => _quotaBytes > _usedBytes ? _quotaBytes - _usedBytes : 0;
  bool   get isThrottled    => _isThrottled;
  double get currentSpeedKBps => _currentSpeedKBps;

  String get formatted {
    final h = (_remainingSeconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((_remainingSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (_remainingSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String get formattedDataRemaining {
    if (_quotaBytes == 0) return '0.00 GB';
    final gb = remainingBytes / (1024 * 1024 * 1024);
    return '${gb.toStringAsFixed(2)} GB';
  }

  String get formattedDataUsed {
    if (_usedBytes == 0) return '0.00 MB';
    if (_usedBytes > 1024 * 1024 * 1024) {
      final gb = _usedBytes / (1024 * 1024 * 1024);
      return '${gb.toStringAsFixed(2)} GB';
    }
    final mb = _usedBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(2)} MB';
  }

  double get progress {
    if (_quotaBytes == 0) return 0.0;
    return (_quotaBytes - _usedBytes) / _quotaBytes;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Fires whenever VpnConnection state changes.
  void _onVpnConnectionChanged() {
    // ── Startup restoration: app killed while VPN was running ──────────
    if (vpnConnection.status == VpnStatus.connected &&
        !isRunning &&
        vpnConnection.isStartupRestoration) {
      start('resume');
      return;
    }

    // ── Network-blip reconnect: VPN dropped and came back on its own ──
    // The underlying AmneziaWG tunnel may briefly flap.  If we weren't
    // explicitly stopped by the user, resume where we left off.
    if (vpnConnection.status == VpnStatus.connected &&
        !isRunning &&
        !_userInitiatedStop &&
        _hasSyncedOnce) {
      debugPrint('[Timer] VPN reconnected after blip — resuming.');
      _resumeTicking();
      return;
    }

    // ── Auto-cleanup when the VPN actually goes down ──────────────────
    if (vpnConnection.status == VpnStatus.disconnected && isRunning) {
      _stopInternal();
    }
  }

  /// Starts the local countdown and begins server polling.
  ///
  /// Values are initialised at 0 — the UI shows "Syncing…" until the first
  /// successful [_syncWithHivemind] returns real data.
  Future<void> start(String adType) async {
    _remainingSeconds    = 0;
    _quotaBytes          = 0;
    _usedBytes           = 0;
    _lastUsedBytes       = 0;
    _currentSpeedKBps    = 0.0;
    _isThrottled         = false;
    _tickCount           = 0;
    _hasSyncedOnce       = false;
    _consecutiveFailures = 0;
    _offlineSeconds      = 0;
    _isDisconnecting     = false;
    _userInitiatedStop   = false;

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);

    notifyListeners();

    // Kick off the first sync — the UI will show real data as soon as it lands.
    _syncWithHivemind();
  }

  void _tick(Timer t) {
    // ── Local countdown ──────────────────────────────────────────────────
    // Decrement the local clock as long as we're not in a network blackout.
    if (_hasSyncedOnce && _consecutiveFailures < _maxConsecutiveFailures) {
      if (_remainingSeconds > 0) {
        _remainingSeconds--;
      }
    }

    // ── Offline watchdog ─────────────────────────────────────────────────
    // If the server has been unreachable for too long, kill the VPN.
    // Don't let an orphaned tunnel keep running forever.
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      _offlineSeconds++;
      if (_offlineSeconds >= _maxOfflineSeconds) {
        debugPrint('[Timer] Offline for $_maxOfflineSeconds s — forcing disconnect.');
        _forceDisconnect('Session lost — server unreachable');
        return;
      }
    }

    // ── Local expiry ─────────────────────────────────────────────────────
    // When our clock hits zero, disconnect immediately.  Don't wait for the
    // next server poll — the session is over and the user expects the VPN
    // to drop right now.
    if (_hasSyncedOnce && _remainingSeconds <= 0) {
      debugPrint('[Timer] Local countdown expired — disconnecting.');
      _forceDisconnect('Session expired');
      return;
    }

    _tickCount++;
    if (_tickCount % _pollIntervalSeconds == 0) {
      _syncWithHivemind();
    }

    // ── Update notification every tick for smooth countdown ─────────────
    // Uses the locally-decremented time so the notification stays in sync
    // with the in-app display, not gated behind the 5 s server poll.
    if (_hasSyncedOnce) {
      final speedText = _currentSpeedKBps > 0.5
          ? '${_currentSpeedKBps.toStringAsFixed(1)} KB/s'
          : 'Idle';
      if (formatted != _lastNotifTime || speedText != _lastNotifSpeed) {
        _lastNotifTime  = formatted;
        _lastNotifSpeed = speedText;
        VpnNotificationManager.showOrUpdateStatus(
          timeLeft: formatted,
          speedKbps: speedText,
        );
      }
    }

    notifyListeners();
  }

  /// Force-disconnects the VPN and stops the timer with a status message.
  /// Used as a local fallback when the server can't be reached.
  void _forceDisconnect(String reason) {
    if (_isDisconnecting) return; // Already tearing down
    debugPrint('[Timer] $reason — forcing disconnect.');
    _timer?.cancel();
    _timer = null;
    _currentSpeedKBps = 0.0;
    _isDisconnecting = true;
    VpnNotificationManager.cancel();
    notifyListeners();
    // Await the disconnect so the tunnel is confirmed down before we
    // consider the session fully cleaned up.
    vpnConnection.disconnect();
  }

  // ── Server Sync ────────────────────────────────────────────────────────────

  Future<void> _syncWithHivemind() async {
    // Never sync while the user is explicitly disconnecting.
    if (_isDisconnecting) return;

    try {
      final deviceId = await CryptoService.getDeviceId();
      final url = Uri.parse(
          '${AppConfig.hivemindApiBase}/session/status?device_id=$deviceId');
      final response = await http.get(url).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        final bool active = data['active'] ?? false;
        if (!active) {
          // Server killed the session — tear down and wait for it.
          stop();
          await vpnConnection.disconnect();
          return;
        }

        _remainingSeconds = data['expires_in_seconds'] ?? _remainingSeconds;
        _quotaBytes       = data['quota_bytes']       ?? _quotaBytes;
        _usedBytes        = data['used_bytes']        ?? _usedBytes;
        _isThrottled      = data['is_throttled']      ?? false;

        // ── Speed calculation over the polling interval ────────────────────
        final int deltaBytes = _usedBytes - _lastUsedBytes;
        if (_hasSyncedOnce && deltaBytes > 0) {
          _currentSpeedKBps = (deltaBytes / _pollIntervalSeconds) / 1000;
        } else if (!_hasSyncedOnce) {
          _currentSpeedKBps = 0.0;
        }
        _lastUsedBytes = _usedBytes;

        // ── Network is healthy — reset failure counters ────────────────────
        _consecutiveFailures = 0;
        _offlineSeconds = 0;
        _hasSyncedOnce = true;

        notifyListeners();
      } else if (response.statusCode == 404) {
        // Peer not found on server (expired / deleted natively)
        stop();
        await vpnConnection.disconnect();
      } else {
        _markSyncFailure();
      }
    } catch (e) {
      debugPrint('Hivemind sync error: $e');
      _markSyncFailure();
    }
  }

  /// Increments the failure counter; pauses the local countdown after
  /// [_maxConsecutiveFailures] to avoid displaying a false "expired" clock.
  void _markSyncFailure() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxConsecutiveFailures) {
      notifyListeners(); // let the UI show "Reconnecting…"
    }
  }

  // ── Bonus Time ─────────────────────────────────────────────────────────────

  /// Called after the user watches a bonus rewarded ad.
  ///
  /// The actual session extension is handled server-side via the AdMob SSV
  /// callback.  This method simply re-syncs so the UI picks up the new
  /// limits and un-throttled status.
  ///
  /// Returns `true` if the sync succeeded, so the UI can decide whether to
  /// show a success snackbar.
  Future<bool> addBonusTime() async {
    try {
      await _syncWithHivemind();
      return _hasSyncedOnce;
    } catch (e) {
      debugPrint('Bonus-time sync error: $e');
      return false;
    }
  }

  // ── Stop ───────────────────────────────────────────────────────────────────

  /// Called externally (e.g. from ConnectButton) to begin tearing down.
  /// Cancels the timer but keeps the notification alive —
  /// [_onVpnConnectionChanged] will do final cleanup when the VPN actually
  /// confirms it's disconnected.
  void stop() {
    _userInitiatedStop = true;
    _isDisconnecting = true;
    _timer?.cancel();
    _timer = null;
    _currentSpeedKBps = 0.0;
    _hasSyncedOnce = false;
    _remainingSeconds = 0;
    notifyListeners();
  }

  /// Restarts the periodic timer without resetting session state.
  /// Used when the VPN reconnects after a brief network blip so we don't
  /// lose track of remaining time / data.
  void _resumeTicking() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
    _isDisconnecting = false;
    _syncWithHivemind();
    notifyListeners();
  }

  /// Internal cleanup — called when VpnConnection confirms disconnected.
  /// Cancels the persistent notification since the tunnel is truly down.
  void _stopInternal() {
    _isDisconnecting = true;
    _timer?.cancel();
    _timer = null;
    _currentSpeedKBps = 0.0;
    _hasSyncedOnce = false;
    VpnNotificationManager.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    vpnConnection.removeListener(_onVpnConnectionChanged);
    _timer?.cancel();
    VpnNotificationManager.cancel();
    super.dispose();
  }
}
