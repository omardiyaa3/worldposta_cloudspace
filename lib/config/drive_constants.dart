// Constants for the WorldPosta Drive backend.
class DriveConstants {
  static const String appName = 'Posta Drive';

  /// Default Drive server (production). Users can override (e.g. a test
  /// instance) at sign-in.
  static const String defaultServerUrl = 'https://drive.worldposta.com';

  /// Where a user mints a `dk_` token in the web UI — shown on the login screen.
  static const String tokenHelpPath = '/me/security';

  /// WorldPosta SSO login base. Opening it directly (with a return_to back to the
  /// Drive) skips loading the Drive SPA first, so the login page appears fast.
  /// Deployment-specific — this is the SSO the portal Drive trusts.
  static const String ssoAuthUrl = 'https://ssotest.worldposta.com/auth';
}
