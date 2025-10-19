//
//  HomeTouchManagerBrowser.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 30/11/2016.
//  Copyright © 2016 Yuval Rakavy. All rights reserved.
//

import Foundation
import UIKit

public class HomeTouchManagerBrowser : NSObject, NetServiceBrowserDelegate {
    private typealias ServiceInfo = (service: NetService, more: Bool)
    private var foundService: PromisedQueue<Bool>? = nil
    
    private var theService: NetService?
    private let defaultManagerName: String?
    private let serviceBrowser: NetServiceBrowser = NetServiceBrowser()
    
    init(defaultManagerName: String?) {
        self.defaultManagerName = defaultManagerName
        super.init()
    }

    public func findManager(searchTimeout: TimeInterval = 4.0) async -> NetService? {
        NSLog("findManager: \(self.defaultManagerName.map(\.debugDescription) ?? "nil")")

        self.serviceBrowser.delegate = self
        self.foundService = PromisedQueue("services")
        
        // Set up timeout task to signal no result
        Task { [] in
            try? await Task.sleep(nanoseconds: UInt64(searchTimeout * 1_000_000_000))
            await MainActor.run {
                if self.foundService != nil {
                    NSLog("Sending false to foundService")
                }
                self.foundService?.send(false)
            }
        }

        self.serviceBrowser.searchForServices(ofType: "_HtVncConf._udp", inDomain: "")

        // Wait for the first result from the promised queue
        let searchResult: Bool = await { () async -> Bool in
            do {
                return try await self.foundService?.wait() ?? false
            } catch {
                NSLog("foundService wait failed with error: \(error)")
                return false
            }
        }()

        NSLog("searchResult: \(searchResult)")

        self.foundService = nil
        self.serviceBrowser.stop()

        var result: NetService? = nil
        if searchResult, let service = self.theService {
            result = await ServiceAddressResolver().resolveServiceAddress(service: service)
            NSLog("Found \(String(describing: result))")
        }

        self.serviceBrowser.delegate = nil
        return result
    }
    
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        NSLog("Found service: \(service.name)")
        if let foundService = self.foundService {
            var done = false
            
            if (self.defaultManagerName != nil && service.name == self.defaultManagerName) {
                NSLog("Found the requried service")
                self.theService = service
                done = true             // That the one, stop
            }
            else if !moreComing {
                // If no more is coming, and this is the only one, select it, otherwise more than one service none is the
                // one that should be chosen
                self.theService = self.theService == nil ? service : nil
                done = true
            }
            else {
                self.theService = service
            }
            
            if done {
                NSLog("Sending true to foundService")
                foundService.send(true)
                foundService.finish()
                self.foundService = nil
            }
        }
    }
}

public class ServiceAddressResolver: NSObject, NetServiceDelegate {
    var fulfill: ((NetService?) -> Void)? = nil
    
    public func resolveServiceAddress(service: NetService, timeout: TimeInterval = 4) async -> NetService? {
        return await withCheckedContinuation { (cont: CheckedContinuation<NetService?, Never>) in
            Task { @MainActor in
                self.fulfill = { resolved in
                    cont.resume(returning: resolved)
                }
                service.delegate = self
                service.resolve(withTimeout: timeout)
            }
        }
    }
    
    public func netServiceDidResolveAddress(_ sender: NetService) {
        sender.delegate = nil
        self.fulfill?(sender)
        self.fulfill = nil
    }
    
    public func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        sender.delegate = nil
        self.fulfill?(nil)
        self.fulfill = nil
    }
}

