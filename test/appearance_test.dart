import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sync_task_app/app_theme.dart';
import 'package:sync_task_app/assistant.dart';
import 'package:sync_task_app/assistant_rings.dart';

void main() {
  testWidgets('Assistant fits narrow and desktop layouts in the dark theme', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final size in [const Size(390, 844), const Size(440, 680)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme,
          home: AssistantScreen(
            key: ValueKey(size),
            client: AssistantClient(
              PocketBase('http://localhost'),
              endpoint: '',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(AssistantScreen));
      expect(Theme.of(context).brightness, Brightness.dark);
      expect(find.byType(AssistantRings), findsNWidgets(2));
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Rings stop when idle and respect reduced motion', (
    tester,
  ) async {
    Future<void> show({
      required bool active,
      bool reducedMotion = false,
      bool animateWhenIdle = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reducedMotion),
            child: AssistantRings(
              active: active,
              animateWhenIdle: animateWhenIdle,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await show(active: true);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await show(active: false);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await show(active: true, reducedMotion: true);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await show(active: false, animateWhenIdle: true);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await show(active: false, animateWhenIdle: true, reducedMotion: true);
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
