# VendorFlow Mobile (Flutter)

Material 3 · Riverpod · GoRouter · Dio · flutter_secure_storage. Talks to the same API as the web app.

```powershell
flutter pub get
flutter run --dart-define=API_URL=http://10.0.2.2:5080/api/v1     # Android emulator -> API on this computer
flutter analyze ; flutter test
```
Screens: sign-in, home (KPIs + actions), approval inbox and detail (approve / reject with comment / request changes),
requisitions (list + new), vendors (list + details with document expiry and performance), purchase orders, receive goods (with photos),
invoices & payments status, notifications, profile. Menus and titles use the organization's display name and vendor terminology.

Android allows plain HTTP only for development (`usesCleartextTraffic`); use HTTPS in production and remove that flag.
