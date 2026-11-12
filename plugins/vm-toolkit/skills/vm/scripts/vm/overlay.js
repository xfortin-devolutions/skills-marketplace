// overlay.js: the images record.py lays over a recording, drawn with AppKit (Homebrew's ffmpeg has no text filter).
//   osascript -l JavaScript overlay.js caption <out.png> <video width> <text>   white text on a dark rounded box
//   osascript -l JavaScript overlay.js ring <out.png> <diameter>                the circle around a click
ObjC.import('Cocoa');
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
    var p = $.NSBezierPath.bezierPathWithOvalInRect($.NSMakeRect(4, 4, d - 8, d - 8));
    $.NSColor.colorWithSRGBRedGreenBlueAlpha(1, 0.8, 0, 0.35).setFill; p.fill;
    p.lineWidth = 5; $.NSColor.colorWithSRGBRedGreenBlueAlpha(1, 0.6, 0, 0.95).setStroke; p.stroke;
    save(rep, out); return;
  }
  var w = parseInt(argv[2]), text = argv[3], pad = 18, size = 26;
  var attrs = $.NSDictionary.dictionaryWithObjectsForKeys(
    $([$.NSFont.systemFontOfSizeWeight(size, 0.3), $.NSColor.whiteColor]),
    $([$.NSFontAttributeName, $.NSForegroundColorAttributeName]));
  var s = $(text);
  var r = s.boundingRectWithSizeOptionsAttributes($.NSMakeSize(w - 4 * pad, 10000), 1 | 2, attrs);
  var tw = Math.ceil(r.size.width), th = Math.ceil(r.size.height);
  var rep = canvas(tw + 2 * pad, th + 2 * pad);
  $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.08, 0.08, 0.1, 0.82).setFill;
  $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius($.NSMakeRect(0, 0, tw + 2 * pad, th + 2 * pad), 12, 12).fill;
  s.drawWithRectOptionsAttributes($.NSMakeRect(pad, pad, tw, th), 1 | 2, attrs);
  save(rep, out);
}
