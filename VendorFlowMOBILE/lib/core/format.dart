import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Amount in rupees with Indian digit grouping, e.g. ₹6,20,000.
String money(num? value, {int decimals = 0}) {
  if (value == null) return '—';
  return NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: decimals).format(value);
}

/// Short amount for small cards: ₹8.8 L, ₹4.82 Cr.
String shortMoney(num? value) {
  final n = (value ?? 0).toDouble();
  if (n >= 10000000) return '₹${(n / 10000000).toStringAsFixed(2)} Cr';
  if (n >= 100000) return '₹${(n / 100000).toStringAsFixed(1)} L';
  return money(n);
}

/// "10 Nov 2026" from an ISO date or date-time text.
String dateText(String? iso) {
  if (iso == null || iso.isEmpty) return '—';
  final d = DateTime.tryParse(iso);
  return d == null ? iso : DateFormat('dd MMM yyyy').format(d.toLocal());
}

/// "PendingApproval" -> "Pending approval".
String statusText(String? status) {
  if (status == null || status.isEmpty) return '';
  final spaced = status.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}');
  final lower = spaced[0] + spaced.substring(1).toLowerCase();
  return lower.replaceAll(RegExp(r'to po$'), 'to PO');
}

/// Colour group of a status (green = good, amber = waiting, red = problem, blue = info, grey = neutral).
Color statusColor(String? status) {
  switch (status) {
    case 'Approved': case 'Active': case 'Valid': case 'Paid': case 'Posted': case 'Matched': case 'Low': case 'FullyReceived': case 'Submitted':
      return const Color(0xFF12A05C);
    case 'Pending': case 'PendingApproval': case 'Medium': case 'Expiring': case 'PartiallyPaid': case 'PartiallyReceived': case 'NeedsReview': case 'Waiting':
      return const Color(0xFFD98A06);
    case 'Rejected': case 'Suspended': case 'Expired': case 'Overdue': case 'High': case 'Disputed': case 'Cancelled':
      return const Color(0xFFDC2D4A);
    case 'Issued': case 'Open': case 'Returned': case 'ReturnedForModification': case 'Registered': case 'ConvertedToPO':
      return const Color(0xFF2B8BE0);
    default:
      return const Color(0xFF6B7394);
  }
}
