//
//  AppDelegate.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 12.10.2015.
//  Copyright © 2015 Yuval Rakavy. All rights reserved.
//

import UIKit
import IQKeyboardManagerSwift

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    var homeTouchController : HomeTouchViewController? {
        get {
            return window?.rootViewController as? HomeTouchViewController
        }
    }

    func application(_: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        IQKeyboardManager.shared.enable = true
        
        if let shortcut = launchOptions?[UIApplication.LaunchOptionsKey.shortcutItem] as? UIApplicationShortcutItem {
            homeTouchController?.changeCurrentHomeTouchManager(name: shortcut.localizedTitle)
        }
        
        return true
    }

    func applicationWillResignActive(_: UIApplication) {
        NSLog("-> applicationWillResignActive");
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_: UIApplication) {
        NSLog("-> applicationDidEnterBackground");
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_: UIApplication) {
        NSLog("-> applicationWillEnterForeground: calling homeTouchController?.reconnect()");
        // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
        homeTouchController?.reconnect()
    }

    func applicationDidBecomeActive(_: UIApplication) {
        NSLog("-> applicationDidBecomeActive");
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
        
        //TODO: homeTouchController?.beginConnectionProcess
    }

    func applicationWillTerminate(_: UIApplication) {
        NSLog("-> applicationWillTerminate");
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }
    
    func application(_: UIApplication, open url: URL) -> Bool {
        if let host = url.host {
            homeTouchController?.changeCurrentHomeTouchManager(name: host)
        }
        
        return true
    }
    
    func application(_: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        homeTouchController?.changeCurrentHomeTouchManager(name: shortcutItem.localizedTitle)
        completionHandler(true)
    }
}

