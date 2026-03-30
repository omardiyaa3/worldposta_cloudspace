import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/constants.dart';

class AuthService extends ChangeNotifier {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  bool _useSecureStorage = true;

  String? _serverUrl;
  String? _username;
  String? _userId; // actual WebDAV user ID (may differ from loginName)
  String? _appPassword;
  String? _displayName;
  bool _isLoggedIn = false;
  bool _isLoading = false;

  String? get serverUrl => _serverUrl;
  String? get username => _username;
  String? get userId => _userId ?? _username; // WebDAV user ID
  String? get appPassword => _appPassword;
  String? get displayName => _displayName;
  bool get isLoggedIn => _isLoggedIn;
  bool get isLoading => _isLoading;

  String get basicAuth {
    final credentials = base64Encode(utf8.encode('$_username:$_appPassword'));
    return 'Basic $credentials';
  }

  Future<String?> _read(String key) async {
    if (_useSecureStorage) {
      try {
        return await _secureStorage.read(key: key);
      } catch (e) {
        debugPrint('Secure storage read failed, falling back to prefs: $e');
        _useSecureStorage = false;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_$key');
  }

  Future<void> _write(String key, String? value) async {
    if (_useSecureStorage) {
      try {
        if (value != null) {
          await _secureStorage.write(key: key, value: value);
        } else {
          await _secureStorage.delete(key: key);
        }
        return;
      } catch (e) {
        debugPrint('Secure storage write failed, falling back to prefs: $e');
        _useSecureStorage = false;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    if (value != null) {
      await prefs.setString('auth_$key', value);
    } else {
      await prefs.remove('auth_$key');
    }
  }

  Future<void> _clearAll() async {
    try { await _secureStorage.deleteAll(); } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    for (final key in ['server_url', 'username', 'app_password', 'display_name']) {
      await prefs.remove('auth_$key');
    }
  }

  Future<void> init() async {
    _serverUrl = await _read('server_url');
    _username = await _read('username');
    _userId = await _read('user_id');
    _appPassword = await _read('app_password');
    _displayName = await _read('display_name');
    _isLoggedIn = _serverUrl != null && _username != null && _appPassword != null;
    notifyListeners();
  }

  /// Login Flow v2 - Step 1: Initiate login
  Future<LoginFlowResult> initiateLoginFlow({String? serverUrl}) async {
    final server = serverUrl ?? AppConstants.defaultServerUrl;
    final url = Uri.parse('$server${AppConstants.loginFlowPath}');

    final response = await http.post(url, headers: {
      'User-Agent': 'CloudSpace/1.0',
    });
    if (response.statusCode != 200) {
      throw Exception('Failed to initiate login flow: ${response.statusCode}');
    }

    final data = json.decode(response.body);
    return LoginFlowResult(
      loginUrl: data['login'] as String,
      pollUrl: data['poll']['endpoint'] as String,
      pollToken: data['poll']['token'] as String,
    );
  }

  /// Login Flow v2 - Step 2: Poll for credentials
  Future<bool> pollLoginFlow(LoginFlowResult flow) async {
    _isLoading = true;
    notifyListeners();

    final url = Uri.parse(flow.pollUrl);
    final deadline = DateTime.now().add(
      const Duration(seconds: AppConstants.loginPollTimeout),
    );

    while (DateTime.now().isBefore(deadline)) {
      try {
        final response = await http.post(
          url,
          body: {'token': flow.pollToken},
        );

        debugPrint('Login poll status: ${response.statusCode}');

        if (response.statusCode == 200) {
          debugPrint('Login poll response: ${response.body}');
          final data = json.decode(response.body);
          _serverUrl = data['server'] as String;
          _username = data['loginName'] as String;
          _appPassword = data['appPassword'] as String;

          debugPrint('Login success: server=$_serverUrl user=$_username');

          await _write('server_url', _serverUrl);
          await _write('username', _username);
          await _write('app_password', _appPassword);

          // Fetch display name
          try {
            await _fetchUserInfo();
          } catch (e) {
            debugPrint('Fetch user info failed (non-fatal): $e');
            _displayName = _username;
          }

          _isLoggedIn = true;
          _isLoading = false;
          notifyListeners();
          return true;
        }
        // 404 means user hasn't authenticated yet, keep polling
      } on http.ClientException catch (e) {
        debugPrint('Login poll network error: $e');
      } on FormatException catch (e) {
        debugPrint('Login poll parse error: $e');
      } catch (e) {
        debugPrint('Login poll unexpected error: $e');
      }

      await Future.delayed(
        const Duration(seconds: AppConstants.loginPollInterval),
      );
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  /// Direct login with credentials (app password)
  Future<bool> loginWithCredentials({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final credentials = base64Encode(utf8.encode('$username:$password'));
      final auth = 'Basic $credentials';

      // Test credentials with a capabilities request
      final url = Uri.parse(
        '$serverUrl${AppConstants.capabilitiesPath}?format=json',
      );
      final response = await http.get(url, headers: {
        'Authorization': auth,
        'OCS-APIRequest': 'true',
      });

      if (response.statusCode == 200) {
        _serverUrl = serverUrl;
        _username = username;
        _appPassword = password;

        await _write('server_url', _serverUrl);
        await _write('username', _username);
        await _write('app_password', _appPassword);

        await _fetchUserInfo();

        _isLoggedIn = true;
        _isLoading = false;
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('Login failed: $e');
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<void> _fetchUserInfo() async {
    try {
      // Use /cloud/user (no username in path) to get current user's actual ID
      // This works for LDAP users where loginName != userId
      final url = Uri.parse(
        '$_serverUrl/ocs/v1.php/cloud/user?format=json',
      );
      final response = await http.get(url, headers: {
        'Authorization': basicAuth,
        'OCS-APIRequest': 'true',
      });

      debugPrint('User info response: ${response.statusCode}');
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final userData = data['ocs']?['data'];
        _displayName = userData?['displayname'] as String? ??
            userData?['display-name'] as String? ?? _username;
        _userId = userData?['id'] as String? ?? _username;
        debugPrint('User info: displayName=$_displayName userId=$_userId loginName=$_username');
        await _write('display_name', _displayName);
        await _write('user_id', _userId);
      }
    } catch (e) {
      debugPrint('Fetch user info failed: $e');
      _displayName = _username;
      _userId = _username;
    }
  }

  Future<void> logout() async {
    await _clearAll();
    _serverUrl = null;
    _username = null;
    _appPassword = null;
    _displayName = null;
    _isLoggedIn = false;
    notifyListeners();
  }
}

class LoginFlowResult {
  final String loginUrl;
  final String pollUrl;
  final String pollToken;

  LoginFlowResult({
    required this.loginUrl,
    required this.pollUrl,
    required this.pollToken,
  });
}
