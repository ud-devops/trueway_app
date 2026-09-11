/// The return timeline, as the backend now sends it.
///
/// Every fixture is a real response, copied from `GET /order-returns/10` on
/// 2026-08-19. The rule the whole feature turns on: **the text comes from the
/// server**. `action.label` is worded for staff — "Resubmit requested by
/// admin", "Mark as completed" — and rendering it would have the shop talking
/// about the customer rather than to them. `title` is the customer's heading,
/// `note` is the store's message, and `action.value` picks an icon and nothing
/// else.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/data/models/order_return.dart';

/// A step the store took: heading, message, no submission.
Map<String, dynamic> _storeStep() => {
      'id': 62,
      'action': {'value': 'approved', 'label': 'Approved'},
      'title': 'Return approved',
      'note': 'your return has approved',
      'submission': null,
      'created_at': '2026-08-14T17:54:47+05:30',
      'created_at_formatted': '14-08-2026 17:54:47',
    };

/// A step the customer took: heading, no message, a full submission.
Map<String, dynamic> _customerStep() => {
      'id': 61,
      'action': {'value': 'resubmitted', 'label': 'Resubmitted by customer'},
      'title': 'Details resubmitted',
      'note': null,
      'submission': {
        'reason': null,
        'customer_comment': 'and typesetting industry. Lorem Ipsum has ...',
        'media_images': [
          'https://dev.truewayerp.com/storage/order-returns/74814-1.webp',
          'https://dev.truewayerp.com/storage/order-returns/74808-2.webp',
        ],
        'media_videos': [
          'https://dev.truewayerp.com/storage/order-returns/74822-1.mp4',
        ],
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

OrderReturn _return({List<Map<String, dynamic>>? histories}) =>
    OrderReturn.fromJson({
      'id': 10,
      'order_id': 198,
      'order_code': 'SF10000198',
      'return_status': {'value': 'resubmit', 'label': 'Resubmit Required'},
      'reason': {'value': 'damaged', 'label': 'Damaged product'},
      'items_count': 1,
      'items': const [],
      'histories': histories ?? [_storeStep(), _customerStep()],
      'latest_history': {
        'id': 55,
        'action': {
          'value': 'resubmit_requested',
          'label': 'Resubmit requested by admin',
        },
        'title': 'More information needed',
        'created_at': '2026-07-06 15:54:01',
      },
    });

void main() {
  group('a store-side step', () {
    test('carries a heading and a message, and no submission', () {
      final step = _return().histories.first;

      expect(step.title, 'Return approved');
      expect(step.note, 'your return has approved');
      expect(step.submission, isNull);
      expect(step.isFromCustomer, isFalse);
    });

    test('the staff wording is parsed but is not the heading', () {
      // It has to be readable for the icon; it must never be what is shown.
      final step = _return().histories.first;

      expect(step.action.value, 'approved');
      expect(step.action.display, 'Approved');
      expect(step.title, isNot(step.action.display));
    });
  });

  group('a customer-side step', () {
    test('carries what was sent', () {
      final step = _return().histories[1];

      expect(step.title, 'Details resubmitted');
      expect(step.note, isNull);
      expect(step.isFromCustomer, isTrue);

      final sent = step.submission!;
      expect(sent.comment, startsWith('and typesetting industry'));
      expect(sent.images, hasLength(2));
      expect(sent.videos, hasLength(1));
      expect(sent.hasMedia, isTrue);
    });

    test('videos are kept apart from images', () {
      // A `.mp4` through an image widget is a permanently-failed thumbnail, so
      // the two lists must not be merged on the way in.
      final sent = _return().histories[1].submission!;

      expect(sent.videos.single, endsWith('.mp4'));
      expect(sent.images.every((u) => !u.endsWith('.mp4')), isTrue);
    });

    test('the items name themselves and their reason', () {
      final item = _return().histories[1].submission!.items.single;

      expect(item.name, contains('Desi Khand'));
      // Already a label, not a slug — nothing to map.
      expect(item.reason, 'Incorrect item');
    });
  });

  group('degenerate shapes', () {
    test('an empty submission object is null, not an empty card', () {
      // A submission block with nothing in it would tell the customer they
      // sent something blank.
      final r = _return(
        histories: [
          {..._storeStep(), 'submission': <String, dynamic>{}},
        ],
      );

      expect(r.histories.single.submission, isNull);
    });

    test('a submission carrying only nulls is null too', () {
      final r = _return(
        histories: [
          {
            ..._storeStep(),
            'submission': {
              'reason': null,
              'customer_comment': null,
              'media_images': <String>[],
              'media_videos': <String>[],
              'items': <Map<String, dynamic>>[],
            },
          },
        ],
      );

      expect(r.histories.single.submission, isNull);
    });

    test('no histories key at all is an empty timeline, not a crash', () {
      // The list endpoint predating this change, and every cached response.
      final r = OrderReturn.fromJson({
        'id': 10,
        'order_id': 198,
        'return_status': {'value': 'pending', 'label': 'Pending'},
        'items': const [],
      });

      expect(r.histories, isEmpty);
      expect(r.hasHistory, isFalse);
    });

    test('an unknown action still keeps its text', () {
      // New steps ship server-side without an app release. The icon falls
      // back; the sentence must not.
      final r = _return(
        histories: [
          {
            ..._storeStep(),
            'action': {'value': 'quarantined', 'label': 'Quarantined by ops'},
            'title': 'On hold',
          },
        ],
      );

      expect(r.histories.single.title, 'On hold');
      expect(r.histories.single.action.value, 'quarantined');
    });
  });

  test('the list row can say where the request is without mapping anything',
      () {
    // `latest_history.title` is why the returns list no longer needs its own
    // status-to-sentence table.
    expect(_return().latestHistory!.title, 'More information needed');
    // ...and it is NOT the staff wording sitting beside it.
    expect(
      _return().latestHistory!.action.display,
      'Resubmit requested by admin',
    );
  });
}
