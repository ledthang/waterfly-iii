import 'dart:convert';

import 'package:chopper/chopper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logging/logging.dart';
import 'package:notifications_listener_service/notifications_listener_service.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:waterflyiii/app.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/generated/swagger_fireflyiii_api/firefly_iii.swagger.dart';
import 'package:waterflyiii/pages/transaction.dart';
import 'package:waterflyiii/settings.dart';

final Logger log = Logger("NotificationListener");

class NotificationTransaction {
  NotificationTransaction(this.appName, this.title, this.body, this.date);

  final String appName;
  final String title;
  final String body;
  final DateTime date;

  NotificationTransaction.fromJson(Map<String, dynamic> json)
    : appName = json['appName'],
      title = json['title'],
      body = json['body'],
      date = DateTime.parse(json['date']);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'appName': appName,
    'title': title,
    'body': body,
    'date': date.toIso8601String(),
  };
}

class NotificationListenerStatus {
  NotificationListenerStatus(
    this.servicePermission,
    this.serviceRunning,
    this.notificationPermission,
  );

  final bool servicePermission;
  final bool serviceRunning;
  final bool notificationPermission;
}

final RegExp rFindMoney = RegExp(
  r'(?:^|\s)(?<preCurrency>(?:[^\r\n\t\f\v 0-9]){0,3})\s*(?<amount>\d[.,\s\d]+(?:[.,]\d+)?)\s*(?<postCurrency>(?:[^\r\n\t\f\v 0-9]){0,3})(?:$|\s)',
);

Future<NotificationListenerStatus> nlStatus() async {
  return NotificationListenerStatus(
    await NotificationServicePlugin.instance.isServicePermissionGranted(),
    await NotificationServicePlugin.instance.isServiceRunning(),
    await FlutterLocalNotificationsPlugin()
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()!
            .areNotificationsEnabled() ??
        false,
  );
}

@pragma('vm:entry-point')
void nlCallback() async {
  log.finest(() => "nlCallback()");
  NotificationServicePlugin.instance.executeNotificationListener((
    NotificationEvent? evt,
  ) async {
    if (evt == null || evt.packageName == null) {
      return;
    }
    if (evt.packageName?.startsWith("com.dreautall.waterflyiii") ?? false) {
      return;
    }
    if (evt.state == NotificationState.remove) {
      return;
    }
    final Iterable<RegExpMatch> matches = rFindMoney.allMatches(evt.text ?? "");
    if (matches.isEmpty) {
      log.finer(() => "nlCallback(${evt.packageName}): no money found");
      return;
    }

    bool validMatch = false;
    for (RegExpMatch match in matches) {
      if ((match.namedGroup("postCurrency")?.isNotEmpty ?? false) ||
          (match.namedGroup("preCurrency")?.isNotEmpty ?? false)) {
        validMatch = true;
        break;
      }
    }
    if (!validMatch) {
      log.finer(
        () => "nlCallback(${evt.packageName}): no money with currency found",
      );
      return;
    }

    final SettingsProvider settings = SettingsProvider();
    await settings.notificationAddKnownApp(evt.packageName!);

    if (!(await settings.notificationUsedApps()).contains(evt.packageName)) {
      log.finer(() => "nlCallback(${evt.packageName}): app not used");
      return;
    }

    final NotificationAppSettings appSettings = await settings
        .notificationGetAppSettings(evt.packageName!);
    bool showNotification = true;

    if (appSettings.autoAdd) {
      tz.initializeTimeZones();
      log.finer(
        () => "nlCallback(${evt.packageName}): trying to auto-add transaction",
      );
      try {
        final FireflyService ffService = FireflyService();
        if (!await ffService.signInFromStorage()) {
          throw UnauthenticatedResponse;
        }
        final FireflyIii api = ffService.api;
        final CurrencyRead localCurrency = ffService.defaultCurrency;
        late CurrencyRead? currency;
        late double amount;

        (currency, amount, _) = await parseNotificationText(
          api,
          evt.text!,
          localCurrency,
          appSettings.expenseRegex ?? "",
          appSettings.incomeRegex ?? "",
        );
        // Fallback solution
        currency ??= localCurrency;

        // Set date
        final DateTime date =
            ffService.tzHandler
                .notificationTXTime(
                  DateTime.tryParse(evt.postTime ?? "") ?? DateTime.now(),
                )
                .toLocal();
        String note = "";
        if (appSettings.autoAdd) {
          note = evt.text ?? "";
        }

        // Check currency
        if (currency != localCurrency) {
          throw Exception("Can't auto-add TX with foreign currency");
        }

        // Check account
        if (appSettings.defaultAccountId == null) {
          throw Exception("Can't auto-add TX with no default account ID");
        }

        final TransactionStore newTx = TransactionStore(
          groupTitle: null,
          transactions: <TransactionSplitStore>[
            TransactionSplitStore(
              type: TransactionTypeProperty.withdrawal,
              date: date,
              amount: amount.toString(),
              description: evt.title!,
              // destinationId
              // destinationName
              notes: note,
              order: 0,
              sourceId: appSettings.defaultAccountId,
            ),
          ],
          applyRules: true,
          fireWebhooks: true,
          errorIfDuplicateHash: true,
        );
        final Response<TransactionSingle> resp = await api.v1TransactionsPost(
          body: newTx,
        );
        if (!resp.isSuccessful || resp.body == null) {
          try {
            final ValidationErrorResponse valError =
                ValidationErrorResponse.fromJson(
                  json.decode(resp.error.toString()),
                );
            throw Exception("nlCallBack PostTransaction: ${valError.message}");
          } catch (_) {
            throw Exception("nlCallBack PostTransaction: unknown");
          }
        }

        FlutterLocalNotificationsPlugin().show(
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
          "Transaction created",
          "Transaction created based on notification ${evt.title}",
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'extract_transaction_created',
              'Transaction from Notification Created',
              channelDescription:
                  'Notification that a Transaction has been created from another Notification.',
              importance: Importance.low, // Android 8.0 and higher
              priority: Priority.low, // Android 7.1 and lower
            ),
          ),
          payload: "",
        );

        showNotification = false;
      } catch (e, stackTrace) {
        log.severe("Error while auto-adding transaction", e, stackTrace);
        showNotification = true;
      }
    }

    if (showNotification) {
      // :TODO: l10n
      FlutterLocalNotificationsPlugin().show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        "Create Transaction?",
        // :TODO: once we l10n this, a better switch can be implemented...
        "Click to create a transaction based on the notification ${evt.title ?? evt.packageName ?? ""}",
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'extract_transaction',
            'Create Transaction from Notification',
            channelDescription:
                'Notification asking to create a transaction from another Notification.',
            importance: Importance.low, // Android 8.0 and higher
            priority: Priority.low, // Android 7.1 and lower
          ),
        ),
        payload: jsonEncode(
          NotificationTransaction(
            evt.packageName ?? "",
            evt.title ?? "",
            evt.text ?? "",
            DateTime.tryParse(evt.postTime ?? "") ?? DateTime.now(),
          ),
        ),
      );
    }
  });
}

Future<void> nlInit() async {
  log.finest(() => "nlInit()");
  await NotificationServicePlugin.instance.initialize(nlCallback);
  nlCallback();
}

Future<void> nlNotificationTap(
  NotificationResponse notificationResponse,
) async {
  log.finest(() => "nlNotificationTap()");
  if (notificationResponse.payload?.isEmpty ?? true) {
    return;
  }
  await showDialog(
    context: navigatorKey.currentState!.context,
    builder:
        (BuildContext context) => TransactionPage(
          notification: NotificationTransaction.fromJson(
            jsonDecode(notificationResponse.payload!),
          ),
        ),
  );
}

Future<(CurrencyRead?, double, bool)> parseNotificationText(
  FireflyIii api,
  String notificationBody,
  CurrencyRead localCurrency,
  String expenseRegex,
  String incomeRegex,
) async {
  CurrencyRead? currency;
  double amount = 0;
  bool isExpense = false;
  int sign = 0; // -1 = expense, +1 = income, 0 = unknown

  // Try to extract some money
  Iterable<RegExpMatch> matches = const <RegExpMatch>[];
  RegExp? chosen;

  if (expenseRegex.isNotEmpty) {
    chosen = RegExp(expenseRegex, caseSensitive: false);
    matches = chosen.allMatches(notificationBody);
    if (matches.isNotEmpty) sign = -1;
  }
  if (matches.isEmpty && incomeRegex.isNotEmpty) {
    chosen = RegExp(incomeRegex, caseSensitive: false);
    matches = chosen.allMatches(notificationBody);
    if (matches.isNotEmpty) sign = 1;
  }
  if (matches.isEmpty) {
    chosen = rFindMoney;
    matches = chosen.allMatches(notificationBody);
  }

  if (matches.isEmpty) {
    log.warning("regex did not match");
    return (currency, amount, isExpense);
  }

  // extract currency
  for (RegExpMatch validMatch in matches) {
    String? currencyStr = validMatch.namedGroup("currency");
    if (currencyStr == null || currencyStr.isEmpty) {
      currencyStr =
          validMatch.namedGroup("preCurrency") ??
          validMatch.namedGroup("postCurrency");
    }

    if (currencyStr != null && currencyStr.isNotEmpty) {
      final String c = currencyStr.trim();
      final String cu = c.toUpperCase();

      if (cu == (localCurrency.attributes.code).toUpperCase() ||
          cu == (localCurrency.attributes.symbol).toUpperCase()) {
        currency = localCurrency;
      } else {
        try {
          final Response<CurrencyArray> response = await api.v1CurrenciesGet();
          if (response.isSuccessful && response.body != null) {
            for (final CurrencyRead cur in response.body!.data) {
              if (cur.attributes.code.toUpperCase() == c ||
                  cur.attributes.symbol.toUpperCase() == c) {
                currency = cur;
                break;
              }
            }
          }
        } catch (e) {
          log.warning("currency lookup failed: $e");
        }
      }
    } else if (chosen != rFindMoney) {
      // Fallback local
      currency = localCurrency;
    }

    // extract amount
    final String amountStr = (validMatch.namedGroup("amount") ?? "").replaceAll(
      RegExp(r"\s+"),
      "",
    );

    if (amountStr.isEmpty) continue;

    final int decimals =
        currency?.attributes.decimalPlaces ??
        localCurrency.attributes.decimalPlaces ??
        2;

    if (decimals == 0) {
      final String digitsOnly = amountStr.replaceAll(RegExp(r"[.,]"), "");
      amount = double.tryParse(digitsOnly) ?? 0;
    } else {
      final String s = amountStr;
      final int lastDot = s.lastIndexOf('.');
      final int lastComma = s.lastIndexOf(',');
      final int decPos = lastDot > lastComma ? lastDot : lastComma;

      if (decPos > 0 && (s.length - decPos - 1) <= 3) {
        final String wholes = s
            .substring(0, decPos)
            .replaceAll(RegExp(r"[.,]"), "");
        final String fracRaw = s
            .substring(decPos + 1)
            .replaceAll(RegExp(r"[.,]"), "");

        final String frac =
            (fracRaw.length > decimals)
                ? fracRaw.substring(0, decimals)
                : fracRaw.padRight(decimals, '0');

        amount = double.tryParse("$wholes.$frac") ?? 0;
      } else {
        amount = double.tryParse(s.replaceAll(RegExp(r"[.,]"), "")) ?? 0;
      }
    }

    isExpense = sign < 0;

    break;
  }

  return (currency, amount, isExpense);
}
