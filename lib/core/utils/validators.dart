/// Input validation shared between the cart and checkout forms.
library;

import '../validation/address_rules.dart';

/// Indian GSTIN: 2-digit state code, 10-char PAN, entity digit, a literal 'Z',
/// then a checksum char. The cart previously accepted anything 15+ characters
/// long, so `AAAAAAAAAAAAAAA` passed.
final RegExp _gstin = RegExp(
  r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$',
);

bool isValidGstin(String? value) {
  final v = value?.trim().toUpperCase();
  if (v == null || v.length != 15) return false;
  return _gstin.hasMatch(v);
}

/// 10-digit Indian mobile number. Leading digit is 6-9 for real subscribers.
///
/// The pattern itself lives in [CheckoutAddressRules.phonePattern] and is read
/// from there, not restated: the address book, the checkout form and this
/// helper must not be able to disagree about what a phone number is.
bool isValidMobile(String? value) {
  final v = value?.trim();
  if (v == null) return false;
  return CheckoutAddressRules.phonePattern.hasMatch(v);
}

/// 6-digit Indian PIN code, first digit 1-9.
///
/// Same rule as [CheckoutAddressRules.zipPattern], read from there rather than
/// copied — see that constant for why the four copies had to collapse.
bool isValidPincode(String? value) {
  final v = value?.trim();
  if (v == null) return false;
  return CheckoutAddressRules.zipPattern.hasMatch(v);
}

/// Pragmatic email check for form feedback.
///
/// Deliberately loose — the server validates properly and its `unique` rule is
/// the real gate. This only exists to catch obvious typos before a round trip,
/// so it must not reject addresses the backend would accept.
final RegExp _email = RegExp(r'^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$');

bool isValidEmail(String? value) {
  final v = value?.trim();
  if (v == null || v.isEmpty) return false;
  // The backend caps email at 60 characters (RegisterRequest).
  if (v.length > 60 || v.length < 6) return false;
  return _email.hasMatch(v);
}

/// Minimum length for a NEW password.
///
/// Stricter than the backend, which only enforces `min:6` — a server will
/// happily accept a stronger password, so raising the bar at registration
/// costs nothing and improves account security.
const int kMinPasswordLength = 8;

/// Compact summary of the rules, for the field's helper text.
///
/// Kept short deliberately: a helper that wraps to three lines pushes the rest
/// of the form around and reads as a warning rather than a hint.
const String kPasswordRequirements =
    '$kMinPasswordLength+ characters · 1 uppercase · 1 lowercase · 1 symbol';

final RegExp _upper = RegExp('[A-Z]');
final RegExp _lower = RegExp('[a-z]');
final RegExp _special = RegExp(r'[!@#$%^&*(),.?":{}|<>\[\]\\/~`_+=;' "'" r'-]');

/// Returns the first unmet requirement, or null when the password is fine.
///
/// Returns the *specific* problem rather than restating every rule, so the
/// customer can fix one thing at a time.
///
/// Applies to setting a password (registration), NOT to signing in — existing
/// accounts may have been created under the backend's older 6-character rule
/// and must still be able to log in.
String? passwordError(String? value) {
  final v = value ?? '';
  if (v.isEmpty) return 'Enter a password';
  if (v.length < kMinPasswordLength) {
    return 'Use at least $kMinPasswordLength characters';
  }
  if (!_upper.hasMatch(v)) return 'Add an uppercase letter (A–Z)';
  if (!_lower.hasMatch(v)) return 'Add a lowercase letter (a–z)';
  if (!_special.hasMatch(v)) return r'Add a special character (! @ # $ …)';
  return null;
}

bool isValidPassword(String? value) => passwordError(value) == null;

/// Letters and spaces, plus the apostrophes and hyphens that appear in real
/// names ("D'Souza", "Anne-Marie"). Digits and other symbols are rejected.
///
/// Backend rule is 2–120 characters.
final RegExp _name = RegExp(r"^[A-Za-z][A-Za-z\s'-]*$");

String? nameError(String? value) {
  final v = value?.trim() ?? '';
  if (v.isEmpty) return 'Enter your name';
  if (v.length < 2) return 'Name is too short';
  if (v.length > 120) return 'Name is too long';
  if (!_name.hasMatch(v)) return 'Use letters only — no numbers or symbols';
  return null;
}

bool isValidName(String? value) => nameError(value) == null;
