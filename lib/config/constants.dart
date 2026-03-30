class AppConstants {
  static const String appName = 'CloudSpace';
  static const String defaultServerUrl = 'https://cloudspace.worldposta.com';
  static const String webDavPath = '/remote.php/dav/files/';
  static const String ocsPath = '/ocs/v2.php';
  static const String loginFlowPath = '/index.php/login/v2';
  static const String statusPath = '/status.php';
  static const String capabilitiesPath = '/ocs/v1.php/cloud/capabilities';
  static const String userInfoPath = '/ocs/v1.php/cloud/users/';
  static const String sharesPath = '/ocs/v2.php/apps/files_sharing/api/v1/shares';
  static const String avatarPath = '/index.php/avatar/';

  static const int chunkSize = 5 * 1024 * 1024; // 5MB
  static const int pollInterval = 30; // seconds
  static const int loginPollInterval = 2; // seconds
  static const int loginPollTimeout = 1200; // 20 minutes in seconds
}
