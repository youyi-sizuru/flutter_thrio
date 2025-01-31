// Copyright (c) 2023 foxsofter.
//
// Do not edit this file.
//

import 'package:flutter_thrio/flutter_thrio.dart';

class Flutter7Route extends NavigatorRouteLeaf {
  factory Flutter7Route(final NavigatorRouteNode parent) =>
      _instance ??= Flutter7Route._(parent);

  Flutter7Route._(super.parent);

  static Flutter7Route? _instance;

  @override
  String get name => 'flutter7';

  Future<TPopParams?> push<TParams, TPopParams>({
    final TParams? params,
    final bool animated = true,
    final NavigatorIntCallback? result,
  }) =>
      ThrioNavigator.push<TParams, TPopParams>(
        url: url,
        params: params,
        animated: animated,
        result: result,
      );

  Future<TPopParams?> pushSingle<TParams, TPopParams>({
    final TParams? params,
    final bool animated = true,
    final NavigatorIntCallback? result,
  }) =>
      ThrioNavigator.pushSingle<TParams, TPopParams>(
        url: url,
        params: params,
        animated: animated,
        result: result,
      );
}
