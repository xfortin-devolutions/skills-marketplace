// overlay.js: the images record.py lays over a recording, drawn with AppKit (Homebrew's ffmpeg has no text filter).
//   osascript -l JavaScript overlay.js caption <out.png> <video width> <text>   white text on a dark rounded box, a
//                                                                              brand-blue bar on its left
//   osascript -l JavaScript overlay.js ring <out.png> <diameter>                the circle around a click (brand blue)
//   osascript -l JavaScript overlay.js highlight <out.png> <w> <h> <dim 0|1> <regions JSON>   a screen-sized layer:
//     each {x, y, width, height, label} outlined GAP pixels outside (top-left origin), the rest dimmed when dim is 1
ObjC.import('Cocoa');
var GAP = 6, LINE = 3;
// Devolutions' brand blue (RDM's Design/Colors.json): primary/blue-brand/400 behind white text (5.3:1), and the dark
// theme's accent/brand/400, a lighter step of it, for lines, which must also show on a dark window.
function rgb(hex, a) {
  var n = parseInt(hex.slice(1), 16);
  return $.NSColor.colorWithSRGBRedGreenBlueAlpha((n >> 16) / 255, (n >> 8 & 255) / 255, (n & 255) / 255, a);
}
var BRAND = rgb('#0068C3', 1), BRAND_LINE = rgb('#0A7FE6', 1);
function highlight(out, W, H, dim, regions) {
  var rep = canvas(W, H);
  // AppKit's origin is bottom-left; a region's is the screenshot's top-left. Each box is the region plus the gap, kept
  // on the screen so a region at its edge still shows its whole outline. Its edges run through pixel centres (+0.5):
  // the odd-width strokes then cover whole pixels, crisp instead of antialiased over two.
  var boxes = regions.map(function (r) {
    var m = 3;
    var x0 = Math.max(m, r.x - GAP), x1 = Math.min(W - m, r.x + r.width + GAP);
    var y0 = Math.max(m, H - r.y - r.height - GAP), y1 = Math.min(H - m, H - r.y + GAP);
    return { r: r, rect: $.NSMakeRect(Math.round(x0) + 0.5, Math.round(y0) + 0.5,
                                      Math.max(Math.round(x1 - x0) - 1, 1), Math.max(Math.round(y1 - y0) - 1, 1)) };
  });
  if (dim) {
    var shade = $.NSBezierPath.bezierPathWithRect($.NSMakeRect(0, 0, W, H));
    boxes.forEach(function (b) { shade.appendBezierPath($.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius(b.rect, 4, 4)); });
    shade.windingRule = $.NSWindingRuleEvenOdd;
    $.NSColor.colorWithSRGBRedGreenBlueAlpha(0, 0, 0, 0.5).setFill; shade.fill;
  }
  var attrs = $.NSDictionary.dictionaryWithObjectsForKeys(
    $([$.NSFont.systemFontOfSizeWeight(15, 0.4), $.NSColor.whiteColor]),
    $([$.NSFontAttributeName, $.NSForegroundColorAttributeName]));
  boxes.forEach(function (b) {
    // White under the blue, then a dark halo: the outline stays readable on a blue control (RDM is full of them), a light
    // window and a dark one alike.
    var p = $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius(b.rect, 4, 4);
    p.lineWidth = LINE + 4; rgb('#000000', 0.4).setStroke; p.stroke;
    p.lineWidth = LINE + 2; $.NSColor.whiteColor.setStroke; p.stroke;
    p.lineWidth = LINE; BRAND_LINE.setStroke; p.stroke;
    if (!b.r.label) return;
    // The label: a tag on the box's top-left corner, outside it (below the box when there is no room above), sitting on
    // the outline's outer edge, at whole pixels so its text is as sharp as the screen's.
    var s = $(b.r.label), size = s.sizeWithAttributes(attrs);
    var tw = Math.ceil(size.width) + 14, th = Math.ceil(size.height) + 6;
    var x = Math.max(0, Math.min(Math.floor(b.rect.origin.x - 1), W - tw));
    var top = Math.floor(b.rect.origin.y + b.rect.size.height - 1);
    var y = top + th <= H ? top : Math.ceil(b.rect.origin.y + 1) - th;
    if (y < 0) y = top - th;  // as tall as the screen: inside its top edge
    BRAND.setFill;
    $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius($.NSMakeRect(x, y, tw, th), 4, 4).fill;
    s.drawAtPointWithAttributes($.NSMakePoint(x + 7, y + 3), attrs);
  });
  save(rep, out);
}
function save(rep, out) {
  $.NSGraphicsContext.restoreGraphicsState;
  rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $({})).writeToFileAtomically(out, true);
}
function canvas(w, h) {
  var rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
    null, w, h, 8, 4, true, false, $.NSDeviceRGBColorSpace, 0, 0);
  $.NSGraphicsContext.saveGraphicsState;
  $.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep));
  return rep;
}
function run(argv) {
  var op = argv[0], out = argv[1];
  if (op === 'ring') {
    var d = parseInt(argv[2]), rep = canvas(d, d);
    // A brand-blue ring edged in white: a blue ring alone would vanish on RDM's blue buttons and selection.
    var p = $.NSBezierPath.bezierPathWithOvalInRect($.NSMakeRect(5, 5, d - 10, d - 10));
    rgb('#0A7FE6', 0.3).setFill; p.fill;
    p.lineWidth = 8; $.NSColor.whiteColor.setStroke; p.stroke;
    p.lineWidth = 5; BRAND_LINE.setStroke; p.stroke;
    save(rep, out); return;
  }
  if (op === 'highlight') { highlight(out, parseInt(argv[2]), parseInt(argv[3]), argv[4] === '1', JSON.parse(argv[5])); return; }
  var w = parseInt(argv[2]), text = argv[3], pad = 18, size = 26;
  var attrs = $.NSDictionary.dictionaryWithObjectsForKeys(
    $([$.NSFont.systemFontOfSizeWeight(size, 0.3), $.NSColor.whiteColor]),
    $([$.NSFontAttributeName, $.NSForegroundColorAttributeName]));
  var s = $(text);
  var r = s.boundingRectWithSizeOptionsAttributes($.NSMakeSize(w - 4 * pad, 10000), 1 | 2, attrs);
  var tw = Math.ceil(r.size.width), th = Math.ceil(r.size.height);
  // White text on a dark box, the brand only as an accent bar on its left: long coloured text tires the eye.
  var bar = 6, bw = tw + 2 * pad + bar, bh = th + 2 * pad;
  var rep = canvas(bw, bh);
  var box = $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius($.NSMakeRect(0, 0, bw, bh), 12, 12);
  rgb('#141419', 0.82).setFill; box.fill;
  $.NSGraphicsContext.saveGraphicsState; box.addClip;
  BRAND_LINE.setFill; $.NSBezierPath.fillRect($.NSMakeRect(0, 0, bar, bh));
  $.NSGraphicsContext.restoreGraphicsState;
  s.drawWithRectOptionsAttributes($.NSMakeRect(bar + pad, pad, tw, th), 1 | 2, attrs);
  save(rep, out);
}
