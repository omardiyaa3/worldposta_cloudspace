// layout.dart — the one width where the app switches to its wide layout
// (sidebar instead of the bottom bar). 600 points: every iPhone in portrait
// stays below it; the unfolded iPhone Duo (669 pt), iPads and desktop windows
// are above it.
import 'package:flutter/widgets.dart';

const double kWideLayoutWidth = 600;

bool isWideLayout(BuildContext context) => MediaQuery.sizeOf(context).width >= kWideLayoutWidth;
