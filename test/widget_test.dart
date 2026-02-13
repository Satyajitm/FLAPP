import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxon_app/app.dart';
import 'package:fluxon_app/core/identity/peer_id.dart';
import 'package:fluxon_app/core/transport/stub_transport.dart';
import 'package:fluxon_app/features/chat/chat_providers.dart';

void main() {
  testWidgets('FluxonApp renders with bottom navigation', (WidgetTester tester) async {
    final peerIdBytes = Uint8List(32);
    final transport = StubTransport(myPeerId: peerIdBytes);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          transportProvider.overrideWithValue(transport),
          myPeerIdProvider.overrideWithValue(PeerId(peerIdBytes)),
        ],
        child: const FluxonApp(),
      ),
    );

    // Verify bottom navigation tabs are present
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('SOS'), findsOneWidget);
  });
}
