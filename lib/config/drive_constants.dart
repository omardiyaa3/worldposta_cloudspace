// Constants for the WorldPosta Drive backend.
class DriveConstants {
  static const String appName = 'Posta Drive';

  /// Default Drive server (production). Users can override (e.g. a test
  /// instance) at sign-in.
  static const String defaultServerUrl = 'https://drive.worldposta.com';

  /// WorldPosta SSO login base. Opening it directly (with a return_to back to the
  /// Drive) skips loading the Drive SPA first, so the login page appears fast.
  /// Deployment-specific — this is the SSO the portal Drive trusts.
  static const String ssoAuthUrl = 'https://admin.worldposta.com';

  /// The SSO's API server — the app's native sign-in calls its mobile endpoints
  /// (/api/auth/login, /api/auth/mfa/verify) here; it is also the token issuer
  /// the Drive trusts.
  static const String ssoApiUrl = 'https://adminserver.worldposta.com';

  /// Public, static pages (no sign-in) — linked from the sign-in screen and
  /// Settings, as App Review asks for the privacy policy inside the app.
  static const String privacyUrl = 'https://drive.worldposta.com/privacy/';
  static const String supportUrl = 'https://drive.worldposta.com/support/';
}
