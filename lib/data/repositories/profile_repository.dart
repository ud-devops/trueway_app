import 'package:dio/dio.dart';

import '../../core/errors/api_exception.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../../core/network/api_response.dart';
import '../models/customer.dart';

/// Writes to the signed-in customer's own record.
///
/// Served by `Botble\Api\Http\Controllers\ProfileController`, every route behind
/// `auth:sanctum`. Reading is [AuthRepository.fetchProfile] (`GET /me`); this
/// class owns the three mutations.
///
/// ## What is actually editable
///
/// `ProfileController::updateProfile` validates `first_name`, `last_name`,
/// `gender` and `description` as well — but `ec_customers` has no such columns
/// and `Customer::$fillable` does not list them, so `$user->fill()` drops them
/// without complaint and the response echoes them back as null. The editable
/// set is exactly `name`, `email`, `phone`, `dob`, plus `avatar` through its own
/// endpoint. Nothing here sends the rest.
///
/// There is no account-deletion endpoint anywhere in the API surface, so the
/// "D" of CRUD does not exist server-side.
class ProfileRepository {
  ProfileRepository(this._api);

  final ApiClient _api;

  /// `PUT /me`.
  ///
  /// Returns the updated customer as the server now holds it — no follow-up
  /// `GET /me` is needed, the controller responds with a fresh `UserResource`.
  ///
  /// **Absent is not the same as null.** Laravel's `nullable` rules let an
  /// explicit `"email": null` through validation, and `fill()` then writes that
  /// null to the column — `ec_customers.email` is nullable, so it would succeed
  /// and wipe the address. The same applies to `phone`, which is how this
  /// customer logs in. Every field is therefore omitted from the body unless the
  /// caller passed it.
  ///
  /// [name] is always sent even when unchanged: the rule is
  /// `required_without:first_name`, and this app never sends `first_name`, so a
  /// body without `name` is a 422.
  ///
  /// [dob] cannot be cleared. The controller applies it under
  /// `if (! empty($data['dob']))`, so an empty value is a no-op rather than a
  /// reset, and there is no other route that unsets it.
  Future<Customer> updateProfile({
    required String name,
    String? email,
    String? phone,
    DateTime? dob,
  }) async {
    final body = <String, dynamic>{'name': name};
    if (email != null) body['email'] = email;
    if (phone != null) body['phone'] = phone;
    if (dob != null) body['dob'] = Customer.apiDob(dob);

    final res = await _api.put(ApiEndpoints.updateProfile, data: body);

    final customer = unwrapObject(res.data, Customer.fromJson);
    if (customer == null || customer.id <= 0) {
      throw ApiException.local(
        'Your profile was saved, but the app could not read it back.',
        developerDetail:
            'PUT ${ApiEndpoints.updateProfile} returned no usable customer: '
            '${res.data}',
      );
    }
    return customer;
  }

  /// `POST /update/avatar` — multipart, single file under the key `avatar`.
  ///
  /// Server rule: `required|image|mimes:jpg,jpeg,png,webp,gif,bmp`, then
  /// `RvMedia::handleUpload` enforces the store's own size ceiling.
  ///
  /// Returns the new avatar URL, or null when the server answers with the
  /// generated-initials placeholder instead of a real one — see
  /// [Customer.fromJson] for why a data URI is treated as "no avatar".
  Future<String?> updateAvatar(String filePath) async {
    final FormData body;
    try {
      body = FormData.fromMap({
        'avatar': await MultipartFile.fromFile(filePath),
      });
    } on Object catch (e) {
      // `MultipartFile.fromFile` stats the path and throws a raw
      // FileSystemException when it is gone — an image_picker temp file the OS
      // reclaimed. Every other exit here is an ApiException, so letting that
      // escape would slip past `on ApiException` handlers.
      throw ApiException.local(
        "That photo couldn't be read. Please pick it again.",
        developerDetail: 'MultipartFile.fromFile failed.\npath: $filePath\n$e',
      );
    }

    final res = await _api.post(ApiEndpoints.updateAvatar, data: body);
    final data = unwrapObject<Map<String, dynamic>>(res.data, (j) => j) ??
        const <String, dynamic>{};
    // Reuse the model's normalisation so a placeholder data URI is filtered out
    // in exactly one place.
    return Customer.fromJson({'id': 1, 'avatar': data['avatar']}).avatar;
  }

  /// `PUT /update/password`.
  ///
  /// Both values are `required|string|min:6|max:60`. A wrong [currentPassword]
  /// comes back **403**, not 401, so it is reported to the user rather than
  /// tearing down the session — [ApiClient.onUnauthorized] only fires on 401.
  ///
  /// The endpoint does not rotate tokens, so the caller stays signed in.
  Future<void> updatePassword({
    required String currentPassword,
    required String newPassword,
  }) =>
      _api.put(
        ApiEndpoints.updatePassword,
        data: {'old_password': currentPassword, 'password': newPassword},
      );
}
