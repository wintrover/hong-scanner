import 'package:flutter/widgets.dart';

import '../state/app_store.dart';

/// Inherited access to the single [AppStore]. Screens read state through
/// [of]; the store's notifications rebuild exactly the widgets that
/// depend on it.
class AppScope extends InheritedNotifier<AppStore> {
  const AppScope({super.key, required AppStore store, required super.child})
      : super(notifier: store);

  static AppStore of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope missing: no AppStore above this widget');
    return scope!.notifier!;
  }
}
