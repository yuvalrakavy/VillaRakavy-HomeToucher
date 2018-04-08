//
//  QueryForServer.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 27/11/2016.
//  Copyright © 2016 Yuval Rakavy. All rights reserved.
//

import Foundation
import UIKit
import PromiseKit

public typealias HostAddress = (hostname: String, port: Int)

public class HomeTouchManager {
    private var serverAddress: Data
    private var resolveRecievedData: ((Data) -> Void)?
    private let receivedData = PromisedQueue<Data?>()
    private var screenSize: CGSize
    private var safeAreaInsets: UIEdgeInsets
    
    init(serverAddress: Data, screenSize: CGSize, safeAreaInsets: UIEdgeInsets) {
        self.serverAddress = serverAddress
        self.screenSize = screenSize
        self.safeAreaInsets = safeAreaInsets
        self.resolveRecievedData = nil
    }
    
    public func getServer(timeout: TimeInterval = 2.0, retryCount: Int = 3) -> Promise<HostAddress?> {
        var result: HostAddress? = nil
        let me = Unmanaged.passUnretained(self).toOpaque().assumingMemoryBound(to: HomeTouchManager.self)
        var context = CFSocketContext(version: 0, info: me, retain: nil, release: nil, copyDescription: nil)
        let socket = withUnsafePointer(to: &context) { CFSocketCreate(nil, PF_INET, SOCK_DGRAM, IPPROTO_UDP, CFSocketCallBackType.dataCallBack.rawValue, onSocketEvent, $0) }
        let runLoopSource = CFSocketCreateRunLoopSource(nil, socket, 100)
        
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.defaultMode)
        
        return firstly {
            PromisedLand.loop(retryCount) { _ in
                if CFSocketSendData(socket, self.serverAddress as CFData?, self.createQuery() as CFData?, 10) != CFSocketError.success {
                    NSLog("Error sending query packet")
                }
                
                let _ = after(seconds: timeout).done { self.receivedData.send(nil) }
                
                return self.receivedData.wait().map { maybeQueryReply in
                    if let queryReply = maybeQueryReply, queryReply.count > 0 {
                        let reply = queryReply.unpackProperties()
                  
                        if let serverName = reply["Server"], let portString = reply["Port"], let port = Int(portString) {
                            result = (serverName, port)
                        }
                        
                        return false        // break the loop - got reply
                    }
                    else {
                        return true         // Continue and try again
                    }
                }
            }
        }.map {_ in
            result
        }.ensure {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.defaultMode)
        }
    }
    
    func onReceived(data: Data) {
        self.receivedData.send(data)
    }
    
    private func createQuery() -> Data {
        func getFormFactor() -> String {
            switch UIDevice.current.userInterfaceIdiom {
                
            case .pad: return "iPad"
            case .phone: return "iPhone"
            default: return "Unknown"
                
            }
        }
        
        let safeTop = String(Int(self.safeAreaInsets.top))
        let safeBottom = String(Int(self.safeAreaInsets.bottom))
        let safeLeft = String(Int(self.safeAreaInsets.left))
        let safeRight = String(Int(self.safeAreaInsets.right))

        return Data([
            "Name": UIDevice.current.name,
            "ScreenWidth": String(Int(self.screenSize.width)),
            "ScreenHeight": String(Int(self.screenSize.height)),
            "FormFactor": getFormFactor(),
            "Device": UIDevice.current.model,
            "Application": "HomeTouch",
            
            "SafeTop": safeTop,
            "SafeBottom": safeBottom,
            "SafeLeft": safeLeft,
            "SafeRight": safeRight

            ].packToBytes()
        )
    }
}

private func onSocketEvent(socket: CFSocket?, callbackType: CFSocketCallBackType, address: CFData?, argData: UnsafeRawPointer?, argInfo: UnsafeMutableRawPointer?) {
    if let info = argInfo {
        let instance = Unmanaged<HomeTouchManager>.fromOpaque(info).takeUnretainedValue()
        
        if callbackType == .dataCallBack {
            if let pData = argData {
                let data = Unmanaged<NSData>.fromOpaque(pData).takeUnretainedValue()
                
                instance.onReceived(data: data as Data)
            }
        }
    }
}
