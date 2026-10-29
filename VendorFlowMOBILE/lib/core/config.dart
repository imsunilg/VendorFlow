/// Address of the VendorFlow API.
/// The Android emulator reaches the computer's localhost through 10.0.2.2.
/// Override at build time:  flutter run --dart-define=API_URL=https://your-server/api/v1
const String apiBase = String.fromEnvironment('API_URL', defaultValue: 'http://10.0.2.2:5230/api/v1');

/// Demo logins, one per role. Shown on the sign-in screen for development/demo builds only.
const bool showDemoAccounts = bool.fromEnvironment('SHOW_DEMO', defaultValue: true);
const String demoPassword = 'Demo@12345';
const List<(String, String)> demoAccounts = [
  ('Organization Owner', 'priya.menon@democompany.in'),
  ('Organization Administrator', 'admin@democompany.in'),
  ('Procurement Manager', 'mark.w@democompany.in'),
  ('Procurement Officer', 'officer@democompany.in'),
  ('Department Manager', 'rahul.d@democompany.in'),
  ('Department Requester', 'anita.rao@democompany.in'),
  ('Approver', 'approver@democompany.in'),
  ('Finance Manager', 'sneha.i@democompany.in'),
  ('Accounts Payable Officer', 'ap@democompany.in'),
  ('Warehouse Manager', 'suresh.j@democompany.in'),
  ('Auditor', 'auditor@democompany.in'),
];
