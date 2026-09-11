import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../data/models/customer.dart';
import '../../data/repositories/profile_repository.dart';
import 'auth_provider.dart';
import 'core_providers.dart';

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(ref.watch(apiClientProvider)),
);

/// In-flight state for the three profile writes.
///
/// [savingDetails] and [savingAvatar] are separate flags rather than one `busy`:
/// the avatar sits above the form on the same screen, and a single flag would
/// grey out the whole form while a photo uploads (and vice versa) for no reason.
class ProfileState {
  const ProfileState({
    this.savingDetails = false,
    this.savingAvatar = false,
    this.savingPassword = false,
    this.error,
    this.notice,
  });

  final bool savingDetails;
  final bool savingAvatar;
  final bool savingPassword;

  /// Last failure, for display. Cleared when the next write starts.
  final String? error;

  /// Transient success message ("Profile updated").
  final String? notice;

  bool get busy => savingDetails || savingAvatar || savingPassword;

  ProfileState copyWith({
    bool? savingDetails,
    bool? savingAvatar,
    bool? savingPassword,
    String? error,
    String? notice,
    bool clearMessages = false,
  }) =>
      ProfileState(
        savingDetails: savingDetails ?? this.savingDetails,
        savingAvatar: savingAvatar ?? this.savingAvatar,
        savingPassword: savingPassword ?? this.savingPassword,
        error: clearMessages ? null : (error ?? this.error),
        notice: clearMessages ? null : (notice ?? this.notice),
      );
}

class ProfileNotifier extends StateNotifier<ProfileState> {
  ProfileNotifier(this._repo, this._ref) : super(const ProfileState());

  final ProfileRepository _repo;
  final Ref _ref;

  /// Saves the editable details and adopts the server's copy of the customer.
  ///
  /// Returns true on success. The server responds with a full `UserResource`,
  /// so what lands in [AuthNotifier.adoptCustomer] is what was actually stored
  /// — not the values that were typed. That matters: the controller accepts
  /// fields it then discards, so echoing the form back would show edits the
  /// database never took.
  Future<bool> saveDetails({
    required String name,
    String? email,
    String? phone,
    DateTime? dob,
  }) async {
    if (state.busy) return false;
    state = state.copyWith(savingDetails: true, clearMessages: true);
    try {
      final customer = await _repo.updateProfile(
        name: name,
        email: email,
        phone: phone,
        dob: dob,
      );
      await _ref.read(authProvider.notifier).adoptCustomer(customer);
      if (!mounted) return true;
      state = state.copyWith(savingDetails: false, notice: 'Profile updated.');
      return true;
    } on ApiException catch (e) {
      if (mounted) {
        state = state.copyWith(savingDetails: false, error: e.message);
      }
      return false;
    }
  }

  /// Uploads a new profile photo.
  ///
  /// The response carries only the new URL, so the rest of the customer is
  /// carried over with [Customer.copyWith] rather than re-reading `/me`.
  Future<bool> uploadAvatar(String filePath) async {
    if (state.busy) return false;

    final before = _ref.read(currentCustomerProvider);
    if (before == null) return false;

    state = state.copyWith(savingAvatar: true, clearMessages: true);
    try {
      final url = await _repo.updateAvatar(filePath);

      // Botble serves avatars through a `thumb` transform of a stored path. If
      // an upload happens to reuse that path, the URL is unchanged and the
      // on-device cache would keep showing the previous photo — which reads as
      // "the upload silently failed". Dropping both entries costs one refetch.
      await _evict(before.avatar);
      await _evict(url);

      // `clearAvatar` rather than relying on a null: the upload succeeded, so
      // what the server now reports is the truth. If that is the generated
      // placeholder, the initials must come back instead of the old photo
      // lingering as if nothing had happened.
      await _ref.read(authProvider.notifier).adoptCustomer(
            before.copyWith(avatar: url, clearAvatar: url == null),
          );
      if (!mounted) return true;
      state = state.copyWith(
        savingAvatar: false,
        notice: 'Profile photo updated.',
      );
      return true;
    } on ApiException catch (e) {
      if (mounted) {
        state = state.copyWith(savingAvatar: false, error: e.message);
      }
      return false;
    }
  }

  /// Changes the account password.
  ///
  /// A wrong [currentPassword] is a 403 carrying "Current password is not
  /// valid!", which surfaces as the error message. The session survives it —
  /// only a 401 signs the customer out.
  Future<bool> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (state.busy) return false;
    state = state.copyWith(savingPassword: true, clearMessages: true);
    try {
      await _repo.updatePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      if (!mounted) return true;
      state = state.copyWith(
        savingPassword: false,
        notice: 'Password changed.',
      );
      return true;
    } on ApiException catch (e) {
      if (mounted) {
        state = state.copyWith(savingPassword: false, error: e.message);
      }
      return false;
    }
  }

  void clearMessages() => state = state.copyWith(clearMessages: true);

  /// Cache eviction is best-effort: a miss throws nothing useful, and failing a
  /// save because an image cache complained would be absurd.
  Future<void> _evict(String? url) async {
    if (url == null || url.isEmpty) return;
    try {
      await CachedNetworkImage.evictFromCache(url);
    } on Object {
      // Ignored deliberately — see above.
    }
  }
}

final profileProvider =
    StateNotifierProvider<ProfileNotifier, ProfileState>(
  (ref) => ProfileNotifier(ref.watch(profileRepositoryProvider), ref),
);
