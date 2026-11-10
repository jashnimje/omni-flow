import 'package:flutter/material.dart';

import 'buttons.dart';

/// A yes or no question, true when the user picks [action]. [destructive]
/// draws the action red, for a step that deletes or cannot be undone, and
/// [body] says what is lost.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  bool destructive = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            key: const ValueKey('confirm-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          OmniButton(
            key: const ValueKey('confirm'),
            label: action,
            expand: false,
            kind: destructive ? OmniButtonKind.danger : OmniButtonKind.primary,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    ) ==
    true;
