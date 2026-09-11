import 'dart:async';

import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/data/models/coupon.dart';
import 'package:trueway_farms/data/models/server_cart.dart';
import 'package:trueway_farms/data/repositories/cart_repository.dart';

/// An in-memory stand-in for the server-side cart.
///
/// The cart is no longer client state, so any test that renders a quantity, a
/// bill or a shipping parcel needs the *server* to hold one. This is the single
/// seam for that: override `cartRepositoryProvider` with one of these and no
/// `ApiClient` — and therefore no socket — is ever constructed.
///
/// It reproduces the parts of the contract the UI depends on:
///
///  * POST **increments** an existing line, PUT sets it absolutely;
///  * every mutation answers with the whole cart, as the real endpoints do;
///  * totals are computed once, here, and simply read back — the same way the
///    app treats the real payload.
///
/// It deliberately does **not** reproduce `Cart::restore()` wiping the cart on a
/// refused mutation (docs/BACKEND_BUGS.md finding 0). That behaviour is pinned
/// in `server_cart_provider_test.dart`, where a hand-built [CartMutationResult]
/// says exactly what survived; making it implicit here would put a destructive
/// side effect in every widget test that happens to hit a stock limit.
class FakeCartRepository implements CartRepository {
  FakeCartRepository({
    this.cartId = 'cart-test',
    List<FakeCartLine> lines = const [],
    this.packageDimensions,
    this.taxRate = 0.05,
  }) : _lines = List.of(lines);

  final String cartId;
  final List<FakeCartLine> _lines;

  /// The box the server's `PackageDimensionCalculator` picked, or null to stand
  /// for the logistics plugin being off. Never computed here — the point of
  /// sourcing it from the server is that the app does not own the rule.
  final Map<String, dynamic>? packageDimensions;

  final double taxRate;

  String? _coupon;
  double _couponDiscount = 0;

  /// Every call, in order, as `'addItem(118, 2)'`. For asserting what went out.
  final List<String> calls = [];

  /// When set, the next mutation is refused with this error and the cart is
  /// returned unchanged — the non-destructive refusal.
  ApiException? nextError;

  /// Holds every mutation open until completed, so a test can inspect the UI
  /// while a cart write is in flight.
  Completer<void>? gate;

  List<FakeCartLine> get lines => List.unmodifiable(_lines);

  // ---- reads -------------------------------------------------------------

  @override
  Future<ServerCart> fetch(String cartId) async {
    calls.add('fetch($cartId)');
    return ServerCart.fromJson(toJson());
  }

  Map<String, dynamic> toJson() {
    final rawSubTotal = _lines.fold<double>(
      0,
      (sum, l) => sum + l.unitPrice * l.quantity,
    );
    final discountedSubTotal = rawSubTotal - _couponDiscount;
    final tax = discountedSubTotal * taxRate;

    return {
      'id': cartId,
      'count': _lines.fold<int>(0, (sum, l) => sum + l.quantity),
      'cart_items': [for (final l in _lines) l.toJson()],
      'total_weight': _lines.fold<double>(
        0,
        (sum, l) => sum + l.weightGrams * l.quantity,
      ),
      if (packageDimensions != null) 'package_dimensions': packageDimensions,
      'raw_sub_total': rawSubTotal,
      'promotion_discount_amount': 0,
      'coupon_discount_amount': _couponDiscount,
      'applied_coupon_code': _coupon,
      'discounted_sub_total': discountedSubTotal,
      'discounted_tax_amount': tax,
      // What the customer pays for goods. Tax is added on top, exactly as the
      // backend does it — the app treating prices as GST-inclusive is the bug
      // this whole rewrite closed.
      'order_total': discountedSubTotal + tax,
    };
  }

  // ---- mutations ---------------------------------------------------------

  CartMutationResult _answer() {
    final error = nextError;
    nextError = null;
    return CartMutationResult(
      cart: ServerCart.fromJson(toJson()),
      error: error,
    );
  }

  int _indexOf(int id) => _lines.indexWhere((l) => l.id == id);

  @override
  Future<CartMutationResult> createCart({
    required int productId,
    int qty = 1,
  }) async {
    calls.add('createCart($productId, $qty)');
    return addItem(cartId: cartId, productId: productId, qty: qty);
  }

  /// POST adds to whatever is already on the line rather than setting it.
  @override
  Future<CartMutationResult> addItem({
    required String cartId,
    required int productId,
    int qty = 1,
  }) async {
    calls.add('addItem($productId, $qty)');
    final open = gate;
    if (open != null) await open.future;
    if (nextError != null) return _answer();

    final at = _indexOf(productId);
    if (at >= 0) {
      _lines[at] = _lines[at].copyWith(quantity: _lines[at].quantity + qty);
    } else {
      _lines.add(FakeCartLine(id: productId, name: 'Product $productId', quantity: qty));
    }
    return _answer();
  }

  @override
  Future<CartMutationResult> setQuantity({
    required String cartId,
    required CartLineId line,
    required int qty,
  }) async {
    calls.add('setQuantity(${line.value}, $qty)');
    final open = gate;
    if (open != null) await open.future;
    if (qty < 1) {
      throw ArgumentError.value(
        qty,
        'qty',
        'must be >= 1; use removeItem() to delete a line',
      );
    }
    if (nextError != null) return _answer();

    final at = _indexOf(line.value);
    if (at >= 0) _lines[at] = _lines[at].copyWith(quantity: qty);
    return _answer();
  }

  @override
  Future<CartMutationResult> removeItem({
    required String cartId,
    required CartLineId line,
  }) async {
    calls.add('removeItem(${line.value})');
    final open = gate;
    if (open != null) await open.future;
    if (nextError != null) return _answer();

    _lines.removeWhere((l) => l.id == line.value);
    return _answer();
  }

  @override
  Future<CartMutationResult> applyCoupon({
    required String cartId,
    required String code,
  }) async {
    calls.add('applyCoupon($code)');
    final open = gate;
    if (open != null) await open.future;
    if (nextError != null) return _answer();

    _coupon = code;
    _couponDiscount = couponDiscountFor(code);
    return _answer();
  }

  @override
  Future<CartMutationResult> removeCoupon({required String cartId}) async {
    calls.add('removeCoupon()');
    if (nextError != null) return _answer();

    _coupon = null;
    _couponDiscount = 0;
    return _answer();
  }

  /// What a code is worth. The server decides this; a test can override the
  /// rule by subclassing, but no rule lives in `lib/` any more.
  double couponDiscountFor(String code) => 100;

  /// The advertised coupon list, and what a test wants it to do.
  ///
  /// Separate from [nextError] on purpose: `GET /coupons` is the one cart-ish
  /// route that neither mutates nor destroys the cart, so a failure here must
  /// not be confused with a mutation failure.
  List<Coupon> coupons = const [];
  Object? couponsError;

  @override
  Future<List<Coupon>> availableCoupons({String? cartId}) async {
    calls.add('availableCoupons($cartId)');
    if (couponsError != null) throw couponsError!;
    return coupons;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        'FakeCartRepository does not implement ${invocation.memberName}',
      );
}

/// One line of the fake cart.
class FakeCartLine {
  const FakeCartLine({
    required this.id,
    required this.name,
    required this.quantity,
    this.unitPrice = 0,
    this.weightGrams = 0,
    this.lengthCm = 0,
    this.wideCm = 0,
    this.heightCm = 0,
    this.variationLabel,
  });

  /// `variation_attributes`, e.g. `"(Pack Size: 1.85 KG (Pack of 1))"`.
  ///
  /// The only link a cart line offers back to the attribute that produced it —
  /// there is no parent id and no attribute id on the line.
  final String? variationLabel;

  /// The **line** id, which for a variable product is the variation id rather
  /// than the id that was added. See [CartLineId].
  final int id;

  final String name;
  final int quantity;

  /// Per unit, **excluding** tax — `price` on the real payload.
  final double unitPrice;

  /// Per unit, in grams. 0 stands for a product the catalogue records no
  /// shipping weight for, which is what makes a quote a floor.
  final double weightGrams;

  final double lengthCm;
  final double wideCm;
  final double heightCm;

  FakeCartLine copyWith({int? quantity}) => FakeCartLine(
        id: id,
        name: name,
        quantity: quantity ?? this.quantity,
        unitPrice: unitPrice,
        weightGrams: weightGrams,
        lengthCm: lengthCm,
        wideCm: wideCm,
        heightCm: heightCm,
        variationLabel: variationLabel,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'row_id': 'row-$id',
        'name': name,
        'quantity': quantity,
        'price': unitPrice,
        'subtotal': unitPrice * quantity,
        if (variationLabel != null) 'variation_attributes': variationLabel,
        // Omitted entirely when unrecorded, so `weight` parses as null and the
        // line counts toward `unweighedLines`.
        if (weightGrams > 0) 'weight': weightGrams,
        if (lengthCm > 0) 'length': lengthCm,
        if (wideCm > 0) 'wide': wideCm,
        if (heightCm > 0) 'height': heightCm,
      };
}
