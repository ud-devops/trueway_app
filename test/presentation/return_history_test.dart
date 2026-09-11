/// Every round of a return, on the return.
///
/// The bug this pins: a return that ran three submissions showed **one**. The
/// screen printed the return's top-level `customer_comment` and
/// `media_images` — which are only ever the newest round — and the timeline
/// that carries the rest was folded shut underneath it.
///
/// The API was never the problem. Live, return 29 (`submission_count: 3`)
/// returns seven steps, three of them the customer's, each with its own files:
/// 1 image + 1 video, then 1 + 1, then 2 + 2.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/design_system/app_theme.dart';
import 'package:trueway_farms/data/models/order_return.dart';
import 'package:trueway_farms/data/repositories/order_repository.dart';
import 'package:trueway_farms/presentation/providers/core_providers.dart';
import 'package:trueway_farms/presentation/screens/orders/return_detail_screen.dart';

/// [images] defaults to **none** on purpose: a real thumbnail URL leaves
/// `CachedNetworkImage` spinning forever under the test binding, so
/// `pumpAndSettle` never returns. Media parsing has its own coverage in
/// test/data/return_timeline_test.dart; these tests are about which rounds
/// reach the screen.
Map<String, dynamic> _submitted({
  required int id,
  required String comment,
  int images = 0,
  String action = 'resubmitted',
  String title = 'Details resubmitted',
}) =>
    {
      'id': id,
      'action': {'value': action, 'label': 'Resubmitted by customer'},
      'title': title,
      'note': null,
      'submission': {
        'customer_comment': comment,
        'media_images': [
          for (var i = 0; i < images; i++)
            'https://dev.truewayerp.com/storage/order-returns/$id-$i.webp',
        ],
        'media_videos': <String>[],
        'items': [
          {
            'product_name': 'Trueway Farms Organic Desi Khand Brown (khandsari)',
            'reason': 'Incorrect item',
            'media_images': <String>[],
            'media_videos': <String>[],
          },
        ],
      },
      'created_at': '2026-08-14T17:53:52+05:30',
    };

Map<String, dynamic> _asked(int id, String note) => {
      'id': id,
      'action': {
        'value': 'resubmit_requested',
        'label': 'Resubmit requested by admin',
      },
      'title': 'More information needed',
      'note': note,
      'submission': null,
      'created_at': '2026-08-14T17:50:00+05:30',
    };

/// Return 29's shape: three rounds, two questions from the store.
Map<String, dynamic> _threeRounds() => {
      'id': 29,
      'order_id': 314,
      'order_code': 'SF10000314',
      'return_status': {'value': 'completed', 'label': 'Completed'},
      'reason': {'value': 'damaged', 'label': 'Damaged product'},
      'submission_count': 3,
      'items': const [],
      // Newest first, as the server orders them.
      'customer_comment': 'the third and newest thing I said',
      'media_images': <String>[],
      'media_videos': <String>[],
      'histories': [
        _submitted(id: 63, comment: 'the third and newest thing I said'),
        _asked(62, 'still not clear, send a wider photo'),
        _submitted(id: 61, comment: 'the second thing I said'),
        _asked(60, 'please photograph the seal'),
        _submitted(
          id: 59,
          comment: 'the first thing I said',
          action: 'created',
          title: 'Return requested',
        ),
      ],
    };

class _FakeRepo implements OrderRepository {
  _FakeRepo(this.row);

  final Map<String, dynamic> row;

  @override
  Future<OrderReturn> orderReturn(int id) async => OrderReturn.fromJson(row);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Future<void> _pump(WidgetTester tester, Map<String, dynamic> row) async {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [orderRepositoryProvider.overrideWithValue(_FakeRepo(row))],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const ReturnDetailScreen(returnId: 29),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every round the customer sent is on screen', (tester) async {
    await _pump(tester, _threeRounds());

    expect(find.text('the first thing I said'), findsOneWidget);
    expect(find.text('the second thing I said'), findsOneWidget);
    expect(find.text('the third and newest thing I said'), findsOneWidget);
  });

  testWidgets('and every message the store sent with them', (tester) async {
    // `admin_feedback` only ever holds the *current* instruction, so the
    // timeline's `note` is the only place the earlier ones survive.
    await _pump(tester, _threeRounds());

    expect(find.text('please photograph the seal'), findsOneWidget);
    expect(find.text('still not clear, send a wider photo'), findsOneWidget);
  });

  testWidgets('the history is open on arrival', (tester) async {
    // Folded, with the newest round also printed above it, a three-round
    // return looked like a one-round return. That was the whole bug.
    await _pump(tester, _threeRounds());

    expect(find.byKey(const Key('return-history-toggle')), findsOneWidget);
    expect(find.text('the first thing I said'), findsOneWidget);
  });

  testWidgets('nothing counts the attempts at the customer', (tester) async {
    // The three-submission cap is the shop's limit, and the server enforces
    // it. Putting a running count on the screen turns asking for help into a
    // countdown, so the heading names the section and nothing else — and the
    // status row carries no "Attempt 2 of 3" either.
    await _pump(tester, _threeRounds());

    expect(find.text('Return history'), findsOneWidget);
    expect(find.textContaining('submissions'), findsNothing);
    expect(find.textContaining('Attempt'), findsNothing);
    expect(find.textContaining('chances left'), findsNothing);
    expect(find.textContaining('of 3'), findsNothing);
  });

  testWidgets('the newest round is not printed twice', (tester) async {
    // The screen used to render the return's top-level `customer_comment` in a
    // "What you told us" block of its own, which is the newest step again.
    await _pump(tester, _threeRounds());

    expect(find.text('the third and newest thing I said'), findsOneWidget);
    expect(find.text('What you told us'), findsNothing);
  });

  testWidgets('a response with no timeline still shows what it has',
      (tester) async {
    // An older server, or anything cached before the timeline shipped. The
    // top-level fields are then genuinely all there is — and the caption that
    // says so is true again.
    await _pump(tester, {
      ..._threeRounds(),
      'histories': <Map<String, dynamic>>[],
      'customer_comment': 'all that survived',
    });

    expect(find.byKey(const Key('return-history-toggle')), findsNothing);
    expect(find.text('What you told us'), findsOneWidget);
    expect(find.text('all that survived'), findsOneWidget);
  });

  testWidgets('a return still waiting shows no countdown on its form',
      (tester) async {
    // `can_resubmit` is what governs the button; how many tries are left is
    // the server's business and stays there.
    await _pump(tester, {
      ..._threeRounds(),
      'return_status': {'value': 'resubmit', 'label': 'Resubmit Required'},
      'can_resubmit': true,
      'submission_count': 2,
    });

    expect(find.text('Resubmit request'), findsOneWidget);
    expect(find.textContaining('chances left'), findsNothing);
    expect(find.textContaining('last chance'), findsNothing);
    expect(find.textContaining('Attempt'), findsNothing);
  });
  testWidgets('a round does not repeat the product names', (tester) async {
    // This catalogue's names run to a line and a half each, and the return's
    // own Items section already lists every one of them with its reason.
    // Repeating three of them inside every round buried the customer's own
    // words under a wall of text they had already read.
    await _pump(tester, _threeRounds());

    expect(find.text('the first thing I said'), findsOneWidget);
    expect(
      find.textContaining('Desi Khand Brown (khandsari)'),
      findsNothing,
    );
    expect(find.textContaining('— Incorrect item'), findsNothing);
  });

  testWidgets('a round with nothing but items draws no empty gap',
      (tester) async {
    // Without the item list there is nothing left to render for it, so the
    // step is its heading and date alone rather than a heading over a hole.
    await _pump(tester, {
      ..._threeRounds(),
      'histories': [
        {
          'id': 59,
          'action': {'value': 'created', 'label': 'x'},
          'title': 'Return requested',
          'note': null,
          'submission': {
            'customer_comment': null,
            'media_images': <String>[],
            'media_videos': <String>[],
            'items': [
              {
                'product_name': 'Trueway Farms Organic Pure Honey',
                'reason': 'Damaged product',
                'media_images': <String>[],
                'media_videos': <String>[],
              },
            ],
          },
          'created_at': '2026-08-14T17:53:52+05:30',
        },
      ],
    });

    expect(find.text('Return requested'), findsOneWidget);
    expect(find.textContaining('Pure Honey'), findsNothing);
  });
}
