// The MIT License (MIT)
//
// Copyright (c) 2019 Hellobike Group
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.

#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#import "NSObject+ThrioSwizzling.h"
#import "NavigatorFlutterEngineFactory.h"
#import "NavigatorLogger.h"
#import "NavigatorPageNotifyProtocol.h"
#import "NavigatorRouteSettings.h"
#import "ThrioNavigator+Internal.h"
#import "ThrioNavigator+JsonDeserializers.h"
#import "ThrioNavigator+PageBuilders.h"
#import "ThrioNavigator+PageObservers.h"
#import "ThrioNavigator+RouteObservers.h"
#import "ThrioNavigator.h"
#import "ThrioRegistryMap.h"
#import "UINavigationController+Navigator.h"
#import "UINavigationController+PopGesture.h"
#import "UIViewController+HidesNavigationBar.h"
#import "UIViewController+Internal.h"
#import "UIViewController+Navigator.h"
#import "UIViewController+WillPopCallback.h"

NS_ASSUME_NONNULL_BEGIN

@interface UINavigationController ()

@end

@implementation UINavigationController (Navigator)

- (UIViewController *_Nullable)thrio_popingViewController {
    return objc_getAssociatedObject(self, _cmd);
}

- (void)setThrio_popingViewController:(UIViewController *_Nullable)viewController {
    objc_setAssociatedObject(self,
                             @selector(thrio_popingViewController),
                             viewController,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - navigation methods

- (void)thrio_pushUrl:(NSString *)url
               params:(id _Nullable)params
             animated:(BOOL)animated
       fromEntrypoint:(NSString *_Nullable)fromEntrypoint
               result:(ThrioNumberCallback _Nullable)result
         poppedResult:(ThrioIdCallback _Nullable)poppedResult {
    @synchronized (self) {
        UIViewController *viewController = [self thrio_createNativeViewControllerWithUrl:url params:params];
        if (viewController) {
            [self thrio_pushViewController:viewController
                                       url:url
                                    params:params
                                  animated:animated
                            fromEntrypoint:fromEntrypoint
                                    result:result
                              poppedResult:poppedResult];
        } else {
            NSString *entrypoint = @"main";
            if (NavigatorFlutterEngineFactory.shared.multiEngineEnabled) {
                entrypoint = [url componentsSeparatedByString:@"/"][1];
            }

            __weak typeof(self) weakself = self;
            ThrioIdCallback readyBlock = ^(id _) {
                NavigatorVerbose(@"push entrypoint: %@, url:%@", entrypoint, url);
                __strong typeof(weakself) strongSelf = weakself;
                if ([strongSelf.topViewController isKindOfClass:NavigatorFlutterViewController.class] &&
                    [[(NavigatorFlutterViewController *)strongSelf.topViewController entrypoint] isEqualToString:entrypoint]) {
                    NavigatorPageRoute *lastRoute = [ThrioNavigator getLastRouteByUrl:url];
                    NSNumber *index = lastRoute ? @(lastRoute.settings.index.integerValue + 1) : @1;
                    [strongSelf.topViewController thrio_pushUrl:url
                                                          index:index
                                                         params:params
                                                       animated:animated
                                                 fromEntrypoint:fromEntrypoint
                                                         result:^(NSNumber *idx) {
                                                             if (idx && [idx boolValue]) {
                                                                 [strongSelf thrio_removePopGesture];
                                                             }
                                                             if (result) {
                                                                 result(idx);
                                                             }
                                                         }                              poppedResult:poppedResult];
                } else {
                    NavigatorFlutterViewController *viewController = [strongSelf thrio_createFlutterViewControllerWithEntrypoint:entrypoint];
                    [strongSelf thrio_pushViewController:viewController
                                                     url:url
                                                  params:params
                                                animated:animated
                                          fromEntrypoint:fromEntrypoint
                                                  result:result
                                            poppedResult:poppedResult];
                }
            };

            [NavigatorFlutterEngineFactory.shared startupWithEntrypoint:entrypoint readyBlock:readyBlock];
        }
    }
}

- (BOOL)thrio_notifyUrl:(NSString *_Nullable)url
                  index:(NSNumber *_Nullable)index
                   name:(NSString *)name
                 params:(id _Nullable)params {
    BOOL isMatch = NO;

    NSArray *vcs = self.viewControllers;
    for (UIViewController *vc in vcs) {
        NavigatorPageRoute *last = url ? [vc thrio_getRouteByUrl:url index:index] : [vc thrio_lastRoute];
        if (last) {
            [vc thrio_notifyUrl:url index:index name:name params:params];
            isMatch = YES;
        }
    }

    return isMatch;
}

- (void)thrio_popParams:(id _Nullable)params
               animated:(BOOL)animated
                 result:(ThrioBoolCallback _Nullable)result {
    UIViewController *vc = self.topViewController;
    if (!vc) {
        if (result) {
            result(NO);
        }
        return;
    }
    if (!vc.thrio_firstRoute) { // 不存在表示页面未经过thrio打开，直接关闭即可
        if (self.viewControllers.count > 1) {
            id vc = [self popViewControllerAnimated:animated];
            if (result) {
                result(vc != nil);
            }
        } else {
            if (result) {
                result(NO);
            }
        }
        return;
    }
    // 仅剩最后一个页面，如果不是 FlutterViewController，则不允许继续pop
    if (vc.thrio_firstRoute == vc.thrio_lastRoute && self.viewControllers.count < 2) {
        if ([vc isKindOfClass:NavigatorFlutterViewController.class]) {
            __weak typeof(self) weakself = self;
            [vc thrio_popParams:params animated:animated inRoot:YES result:^(NSNumber *r) {
                __strong typeof(weakself) strongSelf = weakself;
                if (r && r.boolValue) {
                    // 只有FlutterViewController才能满足条件
                    if (vc.thrio_lastRoute != vc.thrio_firstRoute) {
                        vc.thrio_lastRoute.prev.next = nil;
                        // 只剩一个route的时候，需要添加侧滑返回手势
                        if (vc.thrio_firstRoute == vc.thrio_lastRoute) {
                            [strongSelf thrio_addPopGesture];
                        }
                    }
                }
                if (result) {
                    result(r && r.boolValue);
                }
            }];
        } else {
            if (result) {
                result(NO);
            }
        }
        return;
    }
    __weak typeof(self) weakself = self;
    [vc thrio_popParams:params animated:animated inRoot:NO result:^(NSNumber *r) {
        __strong typeof(weakself) strongSelf = weakself;
        if (r && r.boolValue) {
            // 只有FlutterViewController才能满足条件
            if (vc.thrio_lastRoute != vc.thrio_firstRoute) {
                vc.thrio_lastRoute.prev.next = nil;
                // 只剩一个route的时候，需要添加侧滑返回手势
                if (vc.thrio_firstRoute == vc.thrio_lastRoute) {
                    [strongSelf thrio_addPopGesture];
                }
            }
        }
        // 原生页面返回YES不代表已经pop掉页面
        // 如果存在willPop拦截的情况的，视用户决策决定页面是否关闭
        if (result) {
            result(r && r.boolValue);
        }
    }];
}

- (void)thrio_popToUrl:(NSString *)url
                 index:(NSNumber *_Nullable)index
              animated:(BOOL)animated
                result:(ThrioBoolCallback _Nullable)result {
    UIViewController *vc = [self getViewControllerByUrl:url index:index];
    if (!vc) {
        if (result) {
            result(NO);
        }
        return;
    }

    __weak typeof(self) weakself = self;
    [vc thrio_popToUrl:url index:index animated:animated result:^(BOOL r) {
        __strong typeof(weakself) strongSelf = weakself;
        if (r && vc != strongSelf.topViewController) {
            [strongSelf popToViewController:vc animated:animated];
        }
        if (r && vc.thrio_firstRoute == vc.thrio_lastRoute) {
            [strongSelf thrio_addPopGesture];
        }
        if (result) {
            result(r);
        }
    }];
}

- (void)thrio_removeUrl:(NSString *)url
                  index:(NSNumber *_Nullable)index
               animated:(BOOL)animated
                 result:(ThrioBoolCallback _Nullable)result {
    UIViewController *vc = [self getViewControllerByUrl:url index:index];
    if (!vc) {
        if (result) {
            result(NO);
        }
        return;
    }
    // 仅剩最后一个页面，不允许remove
    if (vc.thrio_firstRoute == vc.thrio_lastRoute && self.viewControllers.count < 2) {
        if (result) {
            result(NO);
        }
        return;
    }

    NavigatorRouteSettings *routeSettings = [vc thrio_getRouteByUrl:url index:index].settings;
    __weak typeof(self) weakself = self;
    [vc thrio_removeUrl:url index:index animated:animated result:^(BOOL r) {
        __strong typeof(weakself) strongSelf = weakself;
        if (r) {
            if (!vc.thrio_firstRoute) {
                NSMutableArray *vcs = [strongSelf.viewControllers mutableCopy];
                if (animated && vc == vcs.lastObject) {
                    [vcs removeObject:vc];
                    [CATransaction begin];
                    [CATransaction setCompletionBlock:^{
                        if (![vc isKindOfClass:NavigatorFlutterViewController.class]) {
                            [ThrioNavigator didRemove:routeSettings];
                        }
                    }];
                    [strongSelf setViewControllers:vcs animated:animated];
                    [CATransaction commit];
                } else {
                    [vcs removeObject:vc];
                    [strongSelf setViewControllers:vcs animated:animated];
                    if (![vc isKindOfClass:NavigatorFlutterViewController.class]) {
                        [ThrioNavigator didRemove:routeSettings];
                    }
                }
            }

            if (vc.thrio_firstRoute == vc.thrio_lastRoute) {
                [strongSelf thrio_addPopGesture];
            }
        }
        if (result) {
            result(r);
        }
    }];
}

- (void)thrio_didPushUrl:(NSString *)url index:(NSNumber *)index {
    UIViewController *vc = [self getViewControllerByUrl:url index:index];
    if (!vc) {
        return;
    }

    [vc thrio_didPushUrl:url index:index];
    if (vc.thrio_firstRoute == vc.thrio_lastRoute) {
        [self thrio_addPopGesture];
    } else {
        [self thrio_removePopGesture];
    }
}

- (void)thrio_didPopUrl:(NSString *)url index:(NSNumber *)index {
    UIViewController *vc = [self getViewControllerByUrl:url index:index];
    if (!vc) {
        return;
    }

    [vc thrio_didPopUrl:url index:index];
    if (vc.thrio_firstRoute == vc.thrio_lastRoute) {
        [self thrio_addPopGesture];
    }
}

- (void)thrio_didPopToUrl:(NSString *)url index:(NSNumber *)index {
    UIViewController *vc = [self getViewControllerByUrl:url index:index];
    if (!vc) {
        return;
    }

    [vc thrio_didPopToUrl:url index:index];
    if (vc.thrio_firstRoute == vc.thrio_lastRoute) {
        [self thrio_addPopGesture];
    }
}

- (void)thrio_didRemoveUrl:(NSString *)url index:(NSNumber *)index {
    UIViewController *vc = [self getViewControllerByUrl:url index:index];
    if (!vc) {
        return;
    }

    [vc thrio_didRemoveUrl:url index:index];
    if (vc.thrio_firstRoute == vc.thrio_lastRoute) {
        [self thrio_addPopGesture];
    }
}

- (NavigatorPageRoute *_Nullable)thrio_lastRoute {
    return self.topViewController.thrio_lastRoute;
}

- (NavigatorPageRoute *_Nullable)thrio_getLastRouteByUrl:(NSString *)url {
    UIViewController *vc = [self getViewControllerByUrl:url index:nil];
    return [vc thrio_getLastRouteByUrl:url];
}

- (NSArray *)thrio_getAllRoutesByUrl:(NSString *_Nullable)url {
    NSArray *vcs = self.viewControllers;
    NSMutableArray *routes = [NSMutableArray array];
    for (UIViewController *vc in vcs) {
        [routes addObjectsFromArray:[vc thrio_getAllRoutesByUrl:url]];
    }
    return routes;
}

- (NavigatorPageRoute *_Nullable)thrio_getLastRouteByEntrypoint:(NSString *)entrypoint {
    NSArray *vcs = [[self.viewControllers reverseObjectEnumerator] allObjects];
    for (UIViewController *vc in vcs) {
        if ([vc isKindOfClass:NavigatorFlutterViewController.class]) {
            NavigatorFlutterViewController *fvc = (NavigatorFlutterViewController *)vc;
            if ([fvc.entrypoint isEqualToString:entrypoint]) {
                return fvc.thrio_lastRoute;
            }
        } else {
            if (!entrypoint || entrypoint.length < 1) {
                return vc.thrio_lastRoute;
            }
        }
    }
    return nil;
}

- (BOOL)thrio_containsUrl:(NSString *)url {
    return [self getViewControllerByUrl:url index:nil] != nil;
}

- (BOOL)thrio_containsUrl:(NSString *)url index:(NSNumber *_Nullable)index {
    return [self getViewControllerByUrl:url index:index] != nil;
}

- (UIViewController *_Nullable)getViewControllerByUrl:(NSString *)url
                                                index:(NSNumber *_Nullable)index {
    if (url.length < 1) {
        return self.topViewController;
    }
    NSArray *vcs = [[self.viewControllers reverseObjectEnumerator] allObjects];
    for (UIViewController *vc in vcs) {
        if ([vc thrio_getRouteByUrl:url index:index]) {
            return vc;
        }
    }
    return nil;
}

#pragma mark - method swizzling

+ (void)load {
    [self instanceSwizzle:@selector(pushViewController:animated:)
              newSelector:@selector(thrio_pushViewController:animated:)];
    [self instanceSwizzle:@selector(popViewControllerAnimated:)
              newSelector:@selector(thrio_popViewControllerAnimated:)];
    [self instanceSwizzle:@selector(popToViewController:animated:)
              newSelector:@selector(thrio_popToViewController:animated:)];
    [self instanceSwizzle:@selector(setViewControllers:)
              newSelector:@selector(thrio_setViewControllers:)];
}

- (void)thrio_pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (!self.topViewController || ![viewController.thrio_hidesNavigationBar_ isEqualToNumber:self.topViewController.thrio_hidesNavigationBar_]) {
        [self setNavigationBarHidden:viewController.thrio_hidesNavigationBar_.boolValue];
    }

    if (![viewController isKindOfClass:NavigatorFlutterViewController.class] && viewController.thrio_firstRoute) {
        [CATransaction begin];
        NavigatorRouteSettings *routeSettings = viewController.thrio_lastRoute.settings;
        [CATransaction setCompletionBlock:^{
            [ThrioNavigator didPush:routeSettings];
        }];
        [self thrio_pushViewController:viewController animated:animated];
        [CATransaction commit];
    } else {
        [self thrio_pushViewController:viewController animated:animated];
    }
}

/// 侧滑返回有个比较坑的点，刚开始侧滑的时候就触发了`popViewControllerAnimated:`，这函数中的逻辑主要是为了避免这个问题
///
- (UIViewController *_Nullable)thrio_popViewControllerAnimated:(BOOL)animated {
    if (!self.thrio_popingViewController) { // 为空表示不是手势触发的pop
        // 如果是FlutterViewController，无视thrio_willPopBlock，willPop在Dart中已经调用过
        if ([self.topViewController isKindOfClass:NavigatorFlutterViewController.class]) {
            if (self.viewControllers.count > 1) {
                // 判断前一个页面如果是NavigatorFlutterViewController，直接将引擎切换到该页面
                UIViewController *vc = [self.viewControllers objectAtIndex:self.viewControllers.count - 2];
                if ([vc isKindOfClass:NavigatorFlutterViewController.class]) {
                    [NavigatorFlutterEngineFactory.shared pushViewController:(NavigatorFlutterViewController *)vc];
                } else {
                    [NavigatorFlutterEngineFactory.shared popViewController:(NavigatorFlutterViewController *)self.topViewController];
                }
                // 判断前一个页面导航栏是否需要切换
                if (self.navigationBarHidden != vc.thrio_hidesNavigationBar_.boolValue) {
                    [self setNavigationBarHidden:vc.thrio_hidesNavigationBar_.boolValue];
                }
            }

            return [self thrio_popViewControllerAnimated:animated];
        }

        // 经过 thrio 打开的原生页面，设置了thrio_willPopBlock
        if (self.topViewController.thrio_willPopBlock && !self.topViewController.thrio_willPopCalling) {
            self.topViewController.thrio_willPopCalling = YES;
            __weak typeof(self) weakself = self;
            __block UIViewController *poppedVC;
            self.topViewController.thrio_willPopBlock(^(BOOL result) {
                __strong typeof(weakself) strongSelf = weakself;
                if (result) {
                    NSArray *vcs = strongSelf.viewControllers;
                    UIViewController *previousVC;
                    if (vcs.count > 1) {
                        previousVC = vcs[vcs.count - 2];
                    }

                    if (strongSelf.topViewController.thrio_firstRoute) {
                        NavigatorRouteSettings *routeSettings = strongSelf.topViewController.thrio_lastRoute.settings;
                        if (animated) {
                            [CATransaction begin];
                            [CATransaction setCompletionBlock:^{
                                [ThrioNavigator didPop:routeSettings];
                            }];
                            poppedVC = [strongSelf thrio_popViewControllerAnimated:animated];
                            [CATransaction commit];
                        } else {
                            poppedVC = [strongSelf thrio_popViewControllerAnimated:animated];
                            [ThrioNavigator didPop:routeSettings];
                        }
                    } else {
                        poppedVC = [strongSelf thrio_popViewControllerAnimated:animated];
                    }
                    // 判断前一个页面导航栏是否需要切换
                    if (previousVC && strongSelf.navigationBarHidden != previousVC.thrio_hidesNavigationBar_.boolValue) {
                        [strongSelf setNavigationBarHidden:previousVC.thrio_hidesNavigationBar_.boolValue];
                    }

                    // 确定要关闭页面，thrio_willPopBlock需要设为nil
                    strongSelf.topViewController.thrio_willPopBlock = nil;
                }
                // 是否调用willPop的标记位恢复NO
                strongSelf.topViewController.thrio_willPopCalling = NO;
            });
            return poppedVC;
        }
    }

    // 经过 thrio 打开的原生页面，默认处理逻辑，添加didPop
    if (![self.topViewController isKindOfClass:NavigatorFlutterViewController.class] &&
        self.topViewController.thrio_firstRoute) {
        NavigatorRouteSettings *routeSettings = self.topViewController.thrio_lastRoute.settings;
        NSArray *vcs = self.viewControllers;

        UIViewController *previousVC;
        if (vcs.count > 1) {
            previousVC = vcs[vcs.count - 2];
        }
        // 判断前一个页面如果是NavigatorFlutterViewController，直接将引擎切换到该页面
        if ([previousVC isKindOfClass:NavigatorFlutterViewController.class]) {
            [NavigatorFlutterEngineFactory.shared pushViewController:(NavigatorFlutterViewController *)previousVC];
        }

        UIViewController *vc;
        if (animated) {
            [CATransaction begin];
            [CATransaction setCompletionBlock:^{
                [ThrioNavigator didPop:routeSettings];
            }];
            vc = [self thrio_popViewControllerAnimated:animated];
            [CATransaction commit];
        } else {
            vc = [self thrio_popViewControllerAnimated:animated];
            [ThrioNavigator didPop:routeSettings];
        }
        if (previousVC) {
            // 判断前一个页面导航栏是否需要切换
            if (self.navigationBarHidden != previousVC.thrio_hidesNavigationBar_.boolValue) {
                [self setNavigationBarHidden:previousVC.thrio_hidesNavigationBar_.boolValue];
            }
        }
        return vc;
    }

    return [self thrio_popViewControllerAnimated:animated];
}

- (NSArray<__kindof UIViewController *> *_Nullable)thrio_popToViewController:(UIViewController *)viewController
                                                                    animated:(BOOL)animated {
    if (![viewController.thrio_hidesNavigationBar_ isEqualToNumber:self.topViewController.thrio_hidesNavigationBar_]) {
        [self setNavigationBarHidden:viewController.thrio_hidesNavigationBar_.boolValue];
    }

    // 处理didPopTo
    if (viewController.thrio_firstRoute &&
        ![viewController isKindOfClass:NavigatorFlutterViewController.class]) {
        NavigatorRouteSettings *routeSettings = viewController.thrio_lastRoute.settings;
        if (animated) {
            [CATransaction begin];
            [CATransaction setCompletionBlock:^{
                [ThrioNavigator didPopTo:routeSettings];
            }];
            NSArray *vcs = [self thrio_popToViewController:viewController animated:animated];
            [CATransaction commit];
            return vcs;
        }
        NSArray *vcs = [self thrio_popToViewController:viewController animated:animated];
        [ThrioNavigator didPopTo:routeSettings];
        return vcs;
    }
    return [self thrio_popToViewController:viewController animated:animated];
}

- (void)thrio_setViewControllers:(NSArray<UIViewController *> *)viewControllers {
    if (viewControllers.count > 0) {
        UIViewController *willPopVC = self.topViewController;
        UIViewController *willShowVC = viewControllers.lastObject;
        if (![willPopVC.thrio_hidesNavigationBar_ isEqualToNumber:willShowVC.thrio_hidesNavigationBar_]) {
            [self setNavigationBarHidden:willShowVC.thrio_hidesNavigationBar_.boolValue];
        }
    }

    [self thrio_setViewControllers:viewControllers];
}

- (void)thrio_didShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    // 记录最后展示的 Route
    ThrioNavigator.pageObservers.lastRoute = viewController.thrio_lastRoute;

    // 如果即将显示的页面为NavigatorFlutterViewController，需要将该页面切换到引擎上
    if ([viewController isKindOfClass:NavigatorFlutterViewController.class]) {
        [NavigatorFlutterEngineFactory.shared pushViewController:(NavigatorFlutterViewController *)viewController];
    }
    // 手势触发的pop，或者UINavigationController的pop方法触发的pop
    if (self.thrio_popingViewController) {
        if (self.thrio_popingViewController == viewController) {
            self.thrio_popingViewController = nil;
        } else {
            __weak typeof(self) weakself = self;
            [self.thrio_popingViewController thrio_popParams:nil animated:animated inRoot:NO result:^(NSNumber *r) {
                __strong typeof(weakself) strongSelf = weakself;
                [strongSelf thrio_lastRoute].next = nil;

                // 刚关掉的是NavigatorFlutterViewController，且当前要显示的页面不是
                // NavigatorFlutterViewController，置空引擎的viewController
                if ([strongSelf.thrio_popingViewController isKindOfClass:NavigatorFlutterViewController.class]) {
                    if (![viewController isKindOfClass:NavigatorFlutterViewController.class]) {
                        [NavigatorFlutterEngineFactory.shared popViewController:(NavigatorFlutterViewController *)strongSelf.thrio_popingViewController];
                    }
                    if (strongSelf.navigationBarHidden != viewController.thrio_hidesNavigationBar_.boolValue) {
                        [strongSelf setNavigationBarHidden:viewController.thrio_hidesNavigationBar_.boolValue];
                    }
                }
                strongSelf.thrio_popingViewController = nil;
            }];
        }
    }
}

#pragma mark - private methods

- (NavigatorFlutterViewController *)thrio_createFlutterViewControllerWithEntrypoint:(NSString *)entrypoint {
    NavigatorFlutterViewController *viewController;
    NavigatorFlutterPageBuilder flutterBuilder = [ThrioNavigator flutterPageBuilder];
    if (flutterBuilder) {
        viewController = flutterBuilder(entrypoint);
    } else {
        viewController = [[NavigatorFlutterViewController alloc] initWithEntrypoint:entrypoint];
    }
    return viewController;
}

- (UIViewController *_Nullable)thrio_createNativeViewControllerWithUrl:(NSString *)url
                                                                params:(NSDictionary *)params {
    UIViewController *viewController;
    NavigatorPageBuilder builder = [ThrioNavigator pageBuilders][url];
    if (builder) {
        id deserializeParams = [ThrioNavigator deserializeParams:params];
        viewController = builder(deserializeParams);
        if (viewController.thrio_hidesNavigationBar_ == nil) {
            viewController.thrio_hidesNavigationBar_ = @NO;
        }
    }
    return viewController;
}

- (void)thrio_pushViewController:(UIViewController *)viewController
                             url:(NSString *)url
                          params:(id _Nullable)params
                        animated:(BOOL)animated
                  fromEntrypoint:(NSString *_Nullable)fromEntrypoint
                          result:(ThrioNumberCallback _Nullable)result
                    poppedResult:(ThrioIdCallback _Nullable)poppedResult {
    if (viewController) {
        NavigatorPageRoute *lastRoute = [ThrioNavigator getLastRouteByUrl:url];
        NSNumber *index = lastRoute ? @(lastRoute.settings.index.integerValue + 1) : @1;
        __weak typeof(self) weakself = self;
        [viewController thrio_pushUrl:url
                                index:index
                               params:params
                             animated:animated
                       fromEntrypoint:fromEntrypoint
                               result:^(NSNumber *idx) {
                                   if (idx && [idx boolValue]) {
                                       __strong typeof(weakself) strongSelf = weakself;
                                       [strongSelf pushViewController:viewController animated:animated];
                                   }
                                   if (result) {
                                       result(idx);
                                   }
                               } poppedResult:poppedResult];
    }
}

@end

NS_ASSUME_NONNULL_END
