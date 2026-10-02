import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/model/jh_layout.dart';
import 'package:jhentai/src/widget/eh_alert_dialog.dart';
import 'package:jhentai/src/widget/eh_context_menu.dart';

void main() {
  tearDown(() {
    styleSetting.actualLayout = LayoutMode.mobileV2;
  });

  testWidgets('EHDialog keeps the upstream Material actions', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: EHDialog(title: 'Delete?', content: 'Confirm'))));

    final AlertDialog dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(dialog.actions, hasLength(2));
    expect(find.byType(TextButton), findsNWidgets(2));
  });

  testWidgets('mobile context menu keeps the upstream action sheet', (tester) async {
    styleSetting.actualLayout = LayoutMode.mobileV2;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showEHContextMenu(context, actions: [const EHContextMenuAction(text: 'Delete')]),
                  child: const Text('Open'),
                ),
              ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Delete'), findsOneWidget);
    expect(find.byType(CupertinoActionSheet), findsOneWidget);
  });
}
