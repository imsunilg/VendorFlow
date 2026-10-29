/// Address of the VendorFlow API.
/// The Android emulator reaches the computer's localhost through 10.0.2.2.
/// Override at build time:  flutter run --dart-define=API_URL=https://your-server/api/v1
const String apiBase = String.fromEnvironment('API_URL', defaultValue: 'http://10.0.2.2:5080/api/v1');
