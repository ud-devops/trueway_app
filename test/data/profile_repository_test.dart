import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/repositories/profile_repository.dart';

/// `ProfileController` contract tests.
///
/// The controller is unusually easy to misuse:
///
///  * it validates `first_name`, `last_name`, `gender` and `description`, none
///    of which exist as `ec_customers` columns, and drops them on `fill()`;
///  * its `nullable` rules mean an explicit null *writes* a null, so sending
///    "unchanged" as null would wipe the customer's email or phone;
///  * `dob` must arrive as `dd-MM-yyyy` (this deployment sets
///    `CMS_DATE_FORMAT="d-m-Y"`) but comes back ISO-8601;
///  * `avatar_url` never returns null — with no uploaded image it returns a
///    generated `data:image/jpeg;base64,…` placeholder.
///
/// Each of those is pinned below.

class _Canned {
  const _Canned(this.statusCode, this.body);
  final int statusCode;
  final Object body;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);

  final Map<String, _Canned> responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final canned = responses[options.path] ??
        const _Canned(404, {'message': 'no canned response'});
    return ResponseBody.fromString(
      jsonEncode(canned.body),
      canned.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<({ProfileRepository repo, _FakeAdapter adapter})> _build(
  Map<String, _Canned> responses,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(responses);
  final dio = Dio()..httpClientAdapter = adapter;
  return (repo: ProfileRepository(ApiClient(prefs: prefs, dio: dio)), adapter: adapter);
}

/// The shape `UserResource` returns.
Map<String, Object?> _userResource({
  String name = 'Asha Kumari',
  String? email = 'asha@example.com',
  String? phone = '9000000001',
  Object? avatar = 'https://cdn.example.com/users/asha.jpg',
  Object? dob,
}) =>
    {
      'error': false,
      'data': {
        'id': 7,
        'name': name,
        'email': email,
        'phone': phone,
        'avatar': avatar,
        'dob': dob,
        // Validated by the controller, absent from the table — always null.
        'gender': null,
        'description': null,
      },
      'message': 'Update profile successfully!',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('updateProfile', () {
    test('sends only name when nothing else changed', () async {
      final t = await _build({'/me': _Canned(200, _userResource())});

      await t.repo.updateProfile(name: 'Asha Kumari');

      final sent = t.adapter.requests.single;
      expect(sent.method, 'PUT');
      // `name` is unconditional: the rule is `required_without:first_name` and
      // this app never sends `first_name`, so omitting it is a 422.
      expect(sent.data, {'name': 'Asha Kumari'});
    });

    // The bug this guards: `nullable` lets an explicit null through validation,
    // `validated()` keeps the key, and `fill()` writes the null. `ec_customers`
    // made email nullable, so it would succeed — and phone is how the customer
    // signs in.
    test('omits unchanged fields rather than sending null', () async {
      final t = await _build({'/me': _Canned(200, _userResource())});

      await t.repo.updateProfile(name: 'Asha Kumari');

      final body = t.adapter.requests.single.data as Map;
      expect(body.containsKey('email'), isFalse);
      expect(body.containsKey('phone'), isFalse);
      expect(body.containsKey('dob'), isFalse);
    });

    test('includes email and phone when supplied', () async {
      final t = await _build({'/me': _Canned(200, _userResource())});

      await t.repo.updateProfile(
        name: 'Asha Kumari',
        email: 'asha.k@example.com',
        phone: '9000000002',
      );

      expect(t.adapter.requests.single.data, {
        'name': 'Asha Kumari',
        'email': 'asha.k@example.com',
        'phone': '9000000002',
      });
    });

    // `date_format:d-m-Y`. ISO would be rejected with a 422, and the failure
    // arrives as one concatenated string with no field mapping, so it would be
    // hard to diagnose from the app.
    test('writes dob as dd-MM-yyyy, not ISO', () async {
      final t = await _build({'/me': _Canned(200, _userResource())});

      await t.repo.updateProfile(
        name: 'Asha Kumari',
        dob: DateTime(1990, 2, 9),
      );

      expect((t.adapter.requests.single.data as Map)['dob'], '09-02-1990');
    });

    // The controller answers with a fresh UserResource, so the caller must not
    // need a second GET /me.
    test('returns the server copy, including a dob it echoed back', () async {
      final t = await _build({
        '/me': _Canned(
          200,
          _userResource(
            name: 'Asha K',
            dob: '1990-02-09T00:00:00.000000Z',
          ),
        ),
      });

      final customer = await t.repo.updateProfile(name: 'Asha Kumari');

      expect(customer.name, 'Asha K');
      expect(customer.dob, DateTime(1990, 2, 9));
    });

    test('fails loudly when the response carries no usable customer', () async {
      final t = await _build({
        '/me': const _Canned(200, {'error': false, 'data': null}),
      });

      await expectLater(
        t.repo.updateProfile(name: 'Asha Kumari'),
        throwsA(isA<ApiException>()),
      );
    });

    // 422 from this controller is `{error: true, message: "Data invalid! ..."}`
    // with no `errors` map — the message is all the app gets.
    test('surfaces the concatenated 422 message', () async {
      final t = await _build({
        '/me': const _Canned(422, {
          'error': true,
          'data': null,
          'message': 'Data invalid! The email has already been taken.',
        }),
      });

      await expectLater(
        t.repo.updateProfile(name: 'Asha', email: 'taken@example.com'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('already been taken'),
          ),
        ),
      );
    });
  });

  group('updateAvatar', () {
    test('posts multipart to /update/avatar and returns the new URL', () async {
      final file = await _tempImage();
      final t = await _build({
        '/update/avatar': const _Canned(200, {
          'error': false,
          'data': {'avatar': 'https://cdn.example.com/users/new.jpg'},
          'message': 'Update avatar successfully!',
        }),
      });

      final url = await t.repo.updateAvatar(file);

      final sent = t.adapter.requests.single;
      expect(sent.method, 'POST');
      expect(sent.data, isA<FormData>());
      expect(
        (sent.data as FormData).files.map((f) => f.key),
        ['avatar'],
        reason: "the controller reads the 'avatar' file off the request",
      );
      expect(url, 'https://cdn.example.com/users/new.jpg');
    });

    // `Customer::avatarUrl` falls back to `Avatar::toBase64()`, which is
    // `toDataUri()`. Persisting that blob or handing it to an image widget is
    // the failure this filters out.
    test('treats a generated data-URI placeholder as no avatar', () async {
      final file = await _tempImage();
      final t = await _build({
        '/update/avatar': const _Canned(200, {
          'error': false,
          'data': {
            'avatar': 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQ==',
          },
        }),
      });

      expect(await t.repo.updateAvatar(file), isNull);
    });

    // image_picker hands back a temp path the OS can reclaim.
    // `MultipartFile.fromFile` throws a bare FileSystemException for it, which
    // would slip past every `on ApiException` handler in the app.
    test('wraps an unreadable file as an ApiException', () async {
      final t = await _build({});

      await expectLater(
        t.repo.updateAvatar('/definitely/not/here.jpg'),
        throwsA(isA<ApiException>()),
      );
      expect(t.adapter.requests, isEmpty, reason: 'nothing should be sent');
    });
  });

  group('updatePassword', () {
    test('sends old_password and password', () async {
      final t = await _build({
        '/update/password': const _Canned(200, {
          'error': false,
          'data': null,
          'message': 'Update password successfully!',
        }),
      });

      await t.repo.updatePassword(
        currentPassword: 'old-secret',
        newPassword: 'new-secret',
      );

      final sent = t.adapter.requests.single;
      expect(sent.method, 'PUT');
      expect(sent.data, {
        'old_password': 'old-secret',
        'password': 'new-secret',
      });
    });

    // 403, not 401 — so this must not be mistaken for a dead session. The
    // client only tears down the session on a 401.
    test('a wrong current password surfaces without unauthorizing', () async {
      final t = await _build({
        '/update/password': const _Canned(403, {
          'error': true,
          'data': null,
          'message': 'Current password is not valid!',
        }),
      });

      await expectLater(
        t.repo.updatePassword(
          currentPassword: 'wrong',
          newPassword: 'new-secret',
        ),
        throwsA(
          isA<ApiException>()
              .having(
                (e) => e.message,
                'message',
                contains('Current password is not valid'),
              )
              .having((e) => e.isUnauthorized, 'isUnauthorized', isFalse),
        ),
      );
    });
  });
}

/// A real file on disk so `MultipartFile.fromFile` can stat it.
Future<String> _tempImage() async {
  final dir = await Directory.systemTemp.createTemp('profile_avatar_test');
  final file = File('${dir.path}/avatar.jpg');
  await file.writeAsBytes(const [0xFF, 0xD8, 0xFF, 0xD9]);
  addTearDown(() async {
    // Best-effort. `MultipartFile.fromFile` opens a read stream that the fake
    // adapter never drains, and Windows refuses to unlink an open file — a
    // leftover temp file in the OS temp directory must not fail the test that
    // otherwise passed.
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Ignored deliberately — see above.
    }
  });
  return file.path;
}
