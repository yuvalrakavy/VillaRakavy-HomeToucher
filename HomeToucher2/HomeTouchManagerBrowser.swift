//
//  HomeTouchManagerBrowser.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 30/11/2016.
//  Copyright © 2016 Yuval Rakavy. All rights reserved.
//

import Foundation
import UIKit
import PromiseKit

public class HomeTouchManagerBrowser : NSObject, NetServiceBrowserDelegate {
    private typealias ServiceInfo = (service: NetService, more: Bool)
    private var foundService: PromisedQueue<Bool>? = PromisedQueue()
    
    private var theService: NetService?
    private let defaultManagerName: String?
    
    init(defaultManagerName: String?) {
        self.defaultManagerName = defaultManagerName
        super.init()
    }

    public func findManager(searchTimeout: TimeInterval = 4.0) -> Promise<NetService?> {
        let serviceBrowser = NetServiceBrowser()
    
        serviceBrowser.delegate = self
        
        _ = after(interval: searchTimeout).then {
            self.foundService?.send(false)
        }
        
        serviceBrowser.searchForServices(ofType: "_HtVncConf._udp", inDomain: "")
        
        return foundService!.wait().then {_ in
            serviceBrowser.stop()
            
            if let service = self.theService {
                
                return ServiceAddressResolver().resolveServiceAddress(service: service).then { aResolvedService in
                    return Promise(value: aResolvedService)
                }
            }
            else {
                return Promise(value: nil)          // Default service not found, or there is more than one
            }
        }.always {
            serviceBrowser.delegate = nil
        }
    }
    
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if let foundService = self.foundService {
            var done = false
            
            if (self.defaultManagerName != nil && service.name == self.defaultManagerName) {
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
                self.foundService = nil
                foundService.send(true)
            }
        }
    }
}

public class ServiceAddressResolver: NSObject, NetServiceDelegate {
    var resolve: ((NetService?) -> Void)? = nil
    
    public func resolveServiceAddress(service: NetService, timeout: TimeInterval = 4) -> Promise<NetService?> {
        service.delegate = self
        service.resolve(withTimeout: timeout)
        
        return Promise() { resolve, reject in
            self.resolve = resolve
        }.always {
            service.delegate = nil
            self.resolve = nil
        }
    }
    
    public func netServiceDidResolveAddress(_ sender: NetService) {
        self.resolve?(sender)
    }
    
    public func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        self.resolve?(nil)
    }
}
