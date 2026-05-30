// test/widget_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';
import 'package:guardianwrist_app/main.dart';
import 'package:guardianwrist_app/app.dart';
import 'package:guardianwrist_app/providers/auth_provider.dart';
import 'package:guardianwrist_app/providers/ble_provider.dart';
import 'package:guardianwrist_app/providers/dashboard_provider.dart';
import 'package:guardianwrist_app/providers/insight_provider.dart';
import 'package:guardianwrist_app/services/iap_service.dart';
import 'package:guardianwrist_app/widgets/metric_card.dart';
import 'package:guardianwrist_app/widgets/empty_state.dart';
import 'package:guardianwrist_app/widgets/loading_overlay.dart';
import 'package:guardianwrist_app/widgets/offline_banner.dart';
import 'package:guardianwrist_app/widgets/section_header.dart';
import 'package:guardianwrist_app/widgets/status_chip.dart';
import 'package:guardianwrist_app/features/auth/screens/login_screen.dart';
import 'package:guardianwrist_app/features/dashboard/screens/dashboard_screen.dart';
import 'package:guardianwrist_app/features/onboarding/screens/onboarding_screen.dart';
import 'package:guardianwrist_app/models/health_record.dart';
import 'package:guardianwrist_app/models/insight.dart';

// Dummy IAPService for testing – matches the real IAPService interface
class FakeIAPService extends IAPService {
  @override
  bool get isPremium => false;

  @override
  Future<void> init() async {}

  //@override
  //Future<List<ProductDetails>> fetchProducts() async => [];

  //@override
  //Future<void> purchase(ProductDetails product) async {}

  //@override
  //Future<void> restorePurchases() async {}

  @override
  void dispose() {}

  // The real IAPService does NOT have getProduct, so remove it.
}

// -------------------------------------------------------------------
// Mock Providers
// -------------------------------------------------------------------
class MockAuthProvider extends AuthProvider {
  @override
  bool get isAuthenticated => true;
  @override
  bool get isLoading => false;
  @override
  String? get error => null;
  // Override any other methods if needed (e.g., signOut, signInWithEmail)
  @override
  Future<void> signOut() async {}
  @override
  Future<void> signInWithEmail(String email, String pw) async {}
  @override
  Future<void> register(String email, String pw, String name) async {}
}

class MockBleProvider extends BleProvider {
  @override
  BleStatus get status => BleStatus.connected;
  @override
  int? get heartRate => 72;
  @override
  int? get spo2 => 98;
  @override
  double? get temperature => 36.6;
  @override
  List<double>? get ecgMv => [];
  // Override other methods to avoid calling real implementations
  @override
  Future<void> startScan() async {}
  @override
  Future<void> connectTo(BluetoothDevice device) async {}
  @override
  Future<void> disconnect() async {}
}

class MockDashboardProvider extends DashboardProvider {
  @override
  List<HealthRecord> get history => [];
  @override
  bool get isLoading => false;
  @override
  String? get error => null;
  @override
  double? get avgHr => 75.0;
  @override
  double? get avgSpo2 => 97.5;
  @override
  bool get hasMore => false;
  @override
  Future<void> loadHistory(
      {DateTime? from, DateTime? to, int page = 0}) async {}
  @override
  Future<void> loadMoreHistory({DateTime? from, DateTime? to}) async {}
  @override
  Future<void> refreshHistory({DateTime? from, DateTime? to}) async {}
}

class MockInsightProvider extends InsightProvider {
  MockInsightProvider() : super(FakeIAPService());
  @override
  List<Insight> get insights => [];
  @override
  bool get isLoading => false;
  @override
  String? get error => null;
  @override
  bool get isPremium => false;
  @override
  Future<void> loadInsights() async {}
  @override
  Future<bool> purchase(String productId) async => false;
  @override
  Future<bool> restorePurchases() async => false;
}

// -------------------------------------------------------------------
// Main test group
// -------------------------------------------------------------------
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('App Structure', () {
    testWidgets('GuardianWristApp builds without crash', (tester) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>(
                create: (_) => MockAuthProvider()),
            ChangeNotifierProvider<BleProvider>(
                create: (_) => MockBleProvider()),
            ChangeNotifierProvider<DashboardProvider>(
                create: (_) => MockDashboardProvider()),
            ChangeNotifierProvider<InsightProvider>(
                create: (_) => MockInsightProvider()),
          ],
          child: const GuardianWristApp(),
        ),
      );
      expect(find.byType(GuardianWristApp), findsOneWidget);
    });
  });

  group('Onboarding Screen', () {
    testWidgets('displays first page correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: OnboardingScreen(),
        ),
      );
      expect(find.text('Real-time health monitoring'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);
    });
  });

  group('Login Screen', () {
    testWidgets('contains email and password fields', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: LoginScreen(),
        ),
      );
      expect(find.byType(TextFormField), findsAtLeast(2));
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Don\'t have an account? Register'), findsOneWidget);
    });
  });

  group('Dashboard Screen', () {
    testWidgets('shows metric cards and navigation bar', (tester) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>(
                create: (_) => MockAuthProvider()),
            ChangeNotifierProvider<BleProvider>(
                create: (_) => MockBleProvider()),
            ChangeNotifierProvider<DashboardProvider>(
                create: (_) => MockDashboardProvider()),
            ChangeNotifierProvider<InsightProvider>(
                create: (_) => MockInsightProvider()),
          ],
          child: const MaterialApp(
            home: DashboardScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.byIcon(Icons.air), findsOneWidget);
      expect(find.byIcon(Icons.thermostat), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });

  group('Widgets', () {
    testWidgets('MetricCard displays values correctly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MetricCard(
              icon: Icons.favorite,
              label: 'Heart Rate',
              value: '72',
              unit: 'bpm',
              color: Colors.red,
            ),
          ),
        ),
      );
      expect(find.text('Heart Rate'), findsOneWidget);
      expect(find.text('72'), findsOneWidget);
      expect(find.text('bpm'), findsOneWidget);
    });

    testWidgets('EmptyState shows title and subtitle', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmptyState(
              icon: Icons.history,
              title: 'No Data',
              subtitle: 'Please sync your watch',
            ),
          ),
        ),
      );
      expect(find.text('No Data'), findsOneWidget);
      expect(find.text('Please sync your watch'), findsOneWidget);
    });

    testWidgets('LoadingOverlay shows progress indicator', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LoadingOverlay(
            isLoading: true,
            child: const Text('Content'),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('OfflineBanner displays correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: OfflineBanner(),
          ),
        ),
      );
      expect(
          find.text('You\'re offline — showing cached data'), findsOneWidget);
    });

    testWidgets('SectionHeader shows title and optional trailing',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SectionHeader(
              'Alerts',
              trailing: const Icon(Icons.settings),
            ),
          ),
        ),
      );
      expect(find.text('Alerts'), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsOneWidget);
    });

    testWidgets('BleStatusChip displays correct text for connected',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BleStatusChip(status: BleStatus.connected),
          ),
        ),
      );
      expect(find.text('Connected'), findsOneWidget);
    });
  });
}
