import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../models/wool_deal.dart';

String statusText(AppLocalizations l10n, WoolStatus status) => switch (status) {
      WoolStatus.planned => l10n.statusPlanned,
      WoolStatus.done => l10n.statusDone,
      WoolStatus.received => l10n.statusReceived,
      WoolStatus.expired => l10n.statusExpired,
    };

Color statusColor(WoolStatus status) => switch (status) {
      WoolStatus.planned => Colors.blueGrey,
      WoolStatus.done => Colors.orange,
      WoolStatus.received => Colors.green,
      WoolStatus.expired => Colors.grey,
    };

IconData statusIcon(WoolStatus status) => switch (status) {
      WoolStatus.planned => Icons.schedule,
      WoolStatus.done => Icons.how_to_reg,
      WoolStatus.received => Icons.check_circle,
      WoolStatus.expired => Icons.event_busy,
    };
