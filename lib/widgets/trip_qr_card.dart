import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr/qr.dart';
import 'package:share_plus/share_plus.dart';

import '../core/theme.dart';
import '../services/trip_qr_text_store.dart';
import '../utils/trip_qr_text.dart';
import 'app_toast.dart';
import 'country_flag_icon.dart';

// The card is an artefact, not a screen: it looks the same in light and
// dark mode and when it leaves the app as an image, so its colours are its
// own rather than the theme's. The gradient is the one on VoyZa's web pages
// and exported itineraries.
const Color _ink = Color(0xFF131A2B);
const Color _inkSoft = Color(0xFF6B7785);
const Color _paper = Color(0xFFFFFFFF);
const Color _backdrop = Color(0xFFDCE5F2);
const List<Color> _brandGradient = [
  Color(0xFF2B1D70),
  Color(0xFF2E5BD0),
  Color(0xFF15BFB6),
];

const double _cardWidth = 300;
const double _cardRadius = 22;
const double _notchRadius = 11;
const double _qrSize = 196;

/// The module grid of the QR code for [data]: `true` is a dark module.
///
/// Error correction M keeps the grid small for a short link, so each module
/// is drawn larger and the code reads from further away.
List<List<bool>> qrModulesFor(String data) {
  final image = QrImage(
    QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
  );
  return [
    for (var row = 0; row < image.moduleCount; row++)
      [
        for (var col = 0; col < image.moduleCount; col++)
          image.isDark(row, col),
      ],
  ];
}

/// A trip as something to hand over: a ticket with the destination on top
/// and, below the tear line, a QR code that holds the trip's share link and
/// nothing else.
class TripQrCard extends StatelessWidget {
  const TripQrCard({
    super.key,
    required this.link,
    required this.shareCode,
    required this.text,
    this.countryCode,
  });

  /// What the QR code holds, exactly as given.
  final String link;

  /// The six-character code, printed small for typing by hand.
  final String shareCode;

  final TripQrText text;

  /// ISO code of the trip's country, for the flag. Null = no flag.
  final String? countryCode;

  @override
  Widget build(BuildContext context) {
    // Fixed type sizes: the ticket is a picture with a set layout, and it
    // is what gets shared. Screen readers get the sentence below instead.
    return MediaQuery.withNoTextScaling(
      child: Semantics(
        container: true,
        image: true,
        label: '${text.sentence}. QR code that opens this trip in VoyZa. '
            'Code TRIP-$shareCode.',
        child: ExcludeSemantics(
          child: ColoredBox(
            color: _backdrop,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(26, 28, 26, 30),
              child: _Ticket(
                link: link,
                shareCode: shareCode,
                text: text,
                countryCode: countryCode,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Ticket extends StatelessWidget {
  const _Ticket({
    required this.link,
    required this.shareCode,
    required this.text,
    required this.countryCode,
  });

  final String link;
  final String shareCode;
  final TripQrText text;
  final String? countryCode;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _cardWidth,
      child: _TicketShape(
        header: _buildDestination(),
        stub: _buildStub(),
      ),
    );
  }

  /// Size of the big line: the country is the loudest thing on the card, so
  /// it gets as much size as its length allows on two lines.
  static double titleSizeFor(String title) {
    final length = title.length;
    if (length <= 9) return 40;
    if (length <= 14) return 34;
    if (length <= 22) return 28;
    if (length <= 34) return 23;
    return 20;
  }

  Widget _buildDestination() {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _brandGradient,
          stops: [0, 0.62, 1],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Text(
                  'VoyZa',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
                const Spacer(),
                if (countryCode != null && countryCode!.length == 2)
                  CountryFlagIcon(countryCode!, height: 18, borderRadius: 4),
              ],
            ),
            const SizedBox(height: 22),
            if (text.lead.isNotEmpty) ...[
              Text(
                text.lead,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.82),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 2),
            ],
            Text(
              text.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: titleSizeFor(text.title),
                height: 1.06,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
              ),
            ),
            if (text.tripName != null || text.stats != null)
              const SizedBox(height: 12),
            if (text.tripName != null)
              Text(
                text.tripName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            if (text.stats != null)
              Padding(
                padding: EdgeInsets.only(top: text.tripName != null ? 2 : 0),
                child: Text(
                  text.stats!,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStub() {
    return ColoredBox(
      color: _paper,
      child: Padding(
        // Four modules of clear paper around the code (a module is
        // 196 / 29 ≈ 6.8 here): scanners use that margin to find it.
        padding: const EdgeInsets.fromLTRB(22, 30, 22, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: _qrSize,
              child: CustomPaint(
                painter: TripQrPainter(modules: qrModulesFor(link)),
              ),
            ),
            const SizedBox(height: 28),
            const Text(
              'Scan to get your own copy',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _ink,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'TRIP-$shareCode',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _inkSoft,
                fontSize: 12,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                letterSpacing: 2.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Header over stub, cut as one ticket: rounded corners, a half-round notch
/// on each side where the two meet, a dashed tear line between the notches,
/// and one shadow that follows the whole outline.
///
/// A render object rather than a clipper: where the header ends is only
/// known once it has been laid out, and the outline has to be right on the
/// very first frame (the card is captured as an image).
class _TicketShape extends MultiChildRenderObjectWidget {
  _TicketShape({required Widget header, required Widget stub})
      : super(children: [header, stub]);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTicket();
}

class _TicketParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderTicket extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _TicketParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _TicketParentData> {
  /// Where the header ends and the stub begins.
  double _tearY = 0;

  final LayerHandle<ClipPathLayer> _clipLayer = LayerHandle<ClipPathLayer>();

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _TicketParentData) {
      child.parentData = _TicketParentData();
    }
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    super.dispose();
  }

  @override
  void performLayout() {
    final width =
        constraints.hasBoundedWidth ? constraints.maxWidth : _cardWidth;
    final childConstraints = BoxConstraints.tightFor(width: width);
    var y = 0.0;
    var child = firstChild;
    while (child != null) {
      child.layout(childConstraints, parentUsesSize: true);
      (child.parentData! as _TicketParentData).offset = Offset(0, y);
      y += child.size.height;
      if (child == firstChild) _tearY = y;
      child = childAfter(child);
    }
    size = constraints.constrain(Size(width, y));
  }

  @override
  double computeMinIntrinsicWidth(double height) => _cardWidth;

  @override
  double computeMaxIntrinsicWidth(double height) => _cardWidth;

  @override
  double computeMinIntrinsicHeight(double width) {
    var total = 0.0;
    var child = firstChild;
    while (child != null) {
      total += child.getMinIntrinsicHeight(width);
      child = childAfter(child);
    }
    return total;
  }

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  Path _outline() {
    final card = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(_cardRadius),
      ));
    final notches = Path()
      ..addOval(
          Rect.fromCircle(center: Offset(0, _tearY), radius: _notchRadius))
      ..addOval(Rect.fromCircle(
          center: Offset(size.width, _tearY), radius: _notchRadius));
    return Path.combine(PathOperation.difference, card, notches);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final outline = _outline();
    context.canvas.drawShadow(
      outline.shift(offset),
      const Color(0xFF1B2A55),
      9,
      false,
    );
    _clipLayer.layer = context.pushClipPath(
      needsCompositing,
      offset,
      Offset.zero & size,
      outline,
      (context, offset) {
        defaultPaint(context, offset);
        _paintTearLine(context.canvas, offset);
      },
      clipBehavior: Clip.antiAlias,
      oldLayer: _clipLayer.layer,
    );
  }

  void _paintTearLine(Canvas canvas, Offset offset) {
    final paint = Paint()
      ..color = const Color(0xFFB9C3D3)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    const dash = 5.0;
    const gap = 5.0;
    const start = _notchRadius + 9;
    final end = size.width - _notchRadius - 9;
    // Just inside the stub, so the dashes sit on paper, not on the gradient.
    final y = offset.dy + _tearY + 0.7;
    for (var x = start; x < end; x += dash + gap) {
      canvas.drawLine(
        Offset(offset.dx + x, y),
        Offset(offset.dx + math.min(x + dash, end), y),
        paint,
      );
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Draws a QR module grid: soft-cornered dark modules on the paper, and the
/// three corner markers as rounded frames so the code looks made for the
/// ticket rather than pasted on it. Every module still sits exactly on the
/// grid and keeps its full width — scanners read position and contrast, and
/// both are untouched.
class TripQrPainter extends CustomPainter {
  const TripQrPainter({required this.modules, this.color = _ink});

  final List<List<bool>> modules;
  final Color color;

  static const int _finder = 7;

  bool _inFinder(int row, int col, int count) {
    final top = row < _finder;
    final left = col < _finder;
    final bottom = row >= count - _finder;
    final right = col >= count - _finder;
    return (top && left) || (top && right) || (bottom && left);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final count = modules.length;
    if (count == 0) return;
    final side = math.min(size.width, size.height);
    final cell = side / count;
    final origin = Offset((size.width - side) / 2, (size.height - side) / 2);
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    final corner = Radius.circular(cell * 0.32);

    for (var row = 0; row < count; row++) {
      for (var col = 0; col < count; col++) {
        if (!modules[row][col] || _inFinder(row, col, count)) continue;
        // A hair of overlap closes the seams anti-aliasing would leave
        // between neighbouring modules.
        final rect = Rect.fromLTWH(
          origin.dx + col * cell - 0.15,
          origin.dy + row * cell - 0.15,
          cell + 0.3,
          cell + 0.3,
        );
        final up = row > 0 && modules[row - 1][col];
        final down = row < count - 1 && modules[row + 1][col];
        final left = col > 0 && modules[row][col - 1];
        final right = col < count - 1 && modules[row][col + 1];
        // Round only the corners that face open paper, so runs of modules
        // read as one solid bar.
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect,
            topLeft: up || left ? Radius.zero : corner,
            topRight: up || right ? Radius.zero : corner,
            bottomLeft: down || left ? Radius.zero : corner,
            bottomRight: down || right ? Radius.zero : corner,
          ),
          paint,
        );
      }
    }

    void finder(int row, int col) {
      final outer = Rect.fromLTWH(
        origin.dx + col * cell,
        origin.dy + row * cell,
        cell * _finder,
        cell * _finder,
      );
      // Frame: a 7×7 square with a 5×5 hole, then the 3×3 centre.
      final frame = Path()
        ..fillType = PathFillType.evenOdd
        ..addRRect(RRect.fromRectAndRadius(outer, Radius.circular(cell * 2.1)))
        ..addRRect(RRect.fromRectAndRadius(
            outer.deflate(cell), Radius.circular(cell * 1.25)));
      canvas.drawPath(frame, paint);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            outer.deflate(cell * 2), Radius.circular(cell * 0.9)),
        paint,
      );
    }

    finder(0, 0);
    finder(0, count - _finder);
    finder(count - _finder, 0);
  }

  @override
  bool shouldRepaint(covariant TripQrPainter oldDelegate) =>
      oldDelegate.color != color || !_sameGrid(oldDelegate.modules, modules);

  static bool _sameGrid(List<List<bool>> a, List<List<bool>> b) {
    if (a.length != b.length) return false;
    for (var r = 0; r < a.length; r++) {
      if (a[r].length != b[r].length) return false;
      for (var c = 0; c < a[r].length; c++) {
        if (a[r][c] != b[r][c]) return false;
      }
    }
    return true;
  }
}

/// The card as a PNG, three device pixels per logical one — sharp enough to
/// print. [boundaryKey] is the key of the [RepaintBoundary] around the card.
Future<ui.Image?> captureTripQrCard(
  GlobalKey boundaryKey, {
  double pixelRatio = 3,
}) async {
  final boundary =
      boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  if (boundary == null) return null;
  return boundary.toImage(pixelRatio: pixelRatio);
}

/// Shows the trip's QR card in a sheet, with a button that shares the card
/// as an image and one that rewrites its headline.
///
/// [text] is the headline made from the trip. With a [tripId], a headline
/// the traveller wrote earlier for this trip replaces it, and a new one is
/// remembered; without one the rewrite lasts as long as the sheet.
Future<void> showTripQrSheet(
  BuildContext context, {
  required String link,
  required String shareCode,
  required TripQrText text,
  String? countryCode,
  String? tripId,
  TripQrTextStore? store,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: AppTheme.sheetBarrierColor(context),
    builder: (_) => _TripQrSheet(
      link: link,
      shareCode: shareCode,
      text: text,
      countryCode: countryCode,
      tripId: tripId,
      store: store ?? TripQrTextStore(),
    ),
  );
}

class _TripQrSheet extends StatefulWidget {
  const _TripQrSheet({
    required this.link,
    required this.shareCode,
    required this.text,
    required this.countryCode,
    required this.tripId,
    required this.store,
  });

  final String link;
  final String shareCode;

  /// The headline made from the trip — what "Use the original" goes back
  /// to.
  final TripQrText text;
  final String? countryCode;
  final String? tripId;
  final TripQrTextStore store;

  @override
  State<_TripQrSheet> createState() => _TripQrSheetState();
}

class _TripQrSheetState extends State<_TripQrSheet> {
  final GlobalKey _cardKey = GlobalKey();
  final GlobalKey _shareButtonKey = GlobalKey();
  bool _sharing = false;

  /// What the card says now: the trip's headline, or the traveller's.
  late TripQrText _text = widget.text;

  @override
  void initState() {
    super.initState();
    _restoreHeadline();
  }

  Future<void> _restoreHeadline() async {
    final tripId = widget.tripId;
    if (tripId == null) return;
    final saved = await widget.store.load(tripId);
    if (saved == null || !mounted) return;
    setState(() {
      _text = widget.text.withHeadline(lead: saved.lead, title: saved.title);
    });
  }

  Future<void> _editHeadline() async {
    final edit = await showDialog<_HeadlineEdit>(
      context: context,
      builder: (_) => _HeadlineDialog(current: _text, original: widget.text),
    );
    if (edit == null || !mounted) return;

    final tripId = widget.tripId;
    final headline = edit.headline;
    if (headline == null) {
      setState(() => _text = widget.text);
      if (tripId != null) await widget.store.clear(tripId);
      return;
    }
    final rewritten =
        widget.text.withHeadline(lead: headline.lead, title: headline.title);
    setState(() => _text = rewritten);
    if (tripId != null && rewritten.isCustom) {
      await widget.store
          .save(tripId, (lead: rewritten.lead, title: rewritten.title));
    }
  }

  Future<void> _shareCard() async {
    if (_sharing) return;
    // Where the share sheet points on iPad — read before any await.
    final box =
        _shareButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;

    setState(() => _sharing = true);
    try {
      final sentence = _text.sentence;
      final image = await captureTripQrCard(_cardKey);
      final data = await image?.toByteData(format: ui.ImageByteFormat.png);
      image?.dispose();
      if (data == null) throw StateError('the card could not be drawn');

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/voyza-trip-${widget.shareCode}.png');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);

      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        text: '$sentence. Scan the code to get this trip in VoyZa.',
        subject: sentence,
        sharePositionOrigin: origin,
      ));
    } catch (e) {
      debugPrint('TripQrSheet share: $e');
      if (mounted) {
        AppToast.error(context, 'Could not share the card. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    // The card keeps its proportions and shrinks to what the screen has
    // left, so the whole code is visible without scrolling. A short screen
    // gives up the explanation line first: the code matters more.
    final compact = media.size.height < 620;
    final cardHeightBudget = math.max(
      260.0,
      media.size.height - media.padding.vertical - (compact ? 214 : 258),
    );

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.sheetBorderColor(context)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Trip QR code',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton.icon(
                  onPressed: _editHeadline,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit text'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            if (!compact)
              Text(
                'Whoever scans it gets their own copy of this trip.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 14),
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: cardHeightBudget),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: RepaintBoundary(
                      key: _cardKey,
                      child: TripQrCard(
                        link: widget.link,
                        shareCode: widget.shareCode,
                        text: _text,
                        countryCode: widget.countryCode,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    key: _shareButtonKey,
                    onPressed: _sharing ? null : _shareCard,
                    icon: _sharing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.ios_share_rounded, size: 18),
                    label: const Text('Share card'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What the headline form came back with: the traveller's two lines, or
/// (with no [headline]) the wish to go back to the trip's own.
class _HeadlineEdit {
  const _HeadlineEdit.rewrite(TripQrHeadline this.headline);
  const _HeadlineEdit.original() : headline = null;

  final TripQrHeadline? headline;
}

/// The two headline lines as a form, laid out in the card's own order: the
/// small line, then the big one.
class _HeadlineDialog extends StatefulWidget {
  const _HeadlineDialog({required this.current, required this.original});

  final TripQrText current;
  final TripQrText original;

  @override
  State<_HeadlineDialog> createState() => _HeadlineDialogState();
}

class _HeadlineDialogState extends State<_HeadlineDialog> {
  late final TextEditingController _lead =
      TextEditingController(text: widget.current.lead);
  late final TextEditingController _title =
      TextEditingController(text: widget.current.title);

  @override
  void dispose() {
    _lead.dispose();
    _title.dispose();
    super.dispose();
  }

  String get _cleanTitle =>
      cleanHeadlinePart(_title.text, TripQrText.maxTitleLength);

  void _save() {
    final title = _cleanTitle;
    if (title.isEmpty) return;
    final lead = cleanHeadlinePart(_lead.text, TripQrText.maxLeadLength);
    final original = widget.original;
    // Typing the original back in is the original, not a rewrite.
    final same = lead == original.lead && title == original.title;
    Navigator.of(context).pop(
      same
          ? const _HeadlineEdit.original()
          : _HeadlineEdit.rewrite((lead: lead, title: title)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final original = widget.original;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Card text'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The two lines at the top of the card. Your trip\'s name and '
              'the code stay as they are.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('trip-qr-lead'),
              cursorOpacityAnimates: false,
              controller: _lead,
              maxLength: TripQrText.maxLeadLength,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Small line',
                hintText: original.lead,
                helperText: 'Leave empty to show only the big line',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('trip-qr-title'),
              cursorOpacityAnimates: false,
              controller: _title,
              maxLength: TripQrText.maxTitleLength,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: 'Big line',
                hintText: original.title,
                errorText:
                    _cleanTitle.isEmpty ? 'The big line needs some text' : null,
              ),
            ),
          ],
        ),
      ),
      actionsOverflowButtonSpacing: 4,
      actions: [
        if (widget.current.isCustom)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(const _HeadlineEdit.original()),
            child: const Text('Use the original'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _cleanTitle.isEmpty ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
