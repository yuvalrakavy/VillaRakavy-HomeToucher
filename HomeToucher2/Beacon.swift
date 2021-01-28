//
//  Beacon.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 31/01/2017.
//  Copyright © 2017 Yuval Rakavy. All rights reserved.
//

import Foundation
import UIKit
import CoreBluetooth
import CoreLocation

public protocol BeaconDelegate {
    var canBeActivated: Bool { get }
    
    func activate(info: iBeaconInfo)
    func deactivate()
}

#if BL_BEACON
class Beacon : NSObject, CBPeripheralManagerDelegate, BeaconDelegate {
    private var _peripheralManager: CBPeripheralManager!
    private var _beaconData : [String : Any]?

    let _uuid: UUID
   
    init(uuid: UUID) {
        self._uuid = uuid

        super.init()
        self._peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        self.doActivate()
    }
    
    var canBeActivated: Bool {
        get { return self._peripheralManager.state == .poweredOn }
    }
    
    private func doActivate() {
        if self.canBeActivated && !self._peripheralManager.isAdvertising {
            if let beaconData = self._beaconData {
                self._peripheralManager.startAdvertising(beaconData)
            }
        }
        else {
            if self._peripheralManager.isAdvertising {
                self._peripheralManager.stopAdvertising()
            }
        }
    }
    
    func activate(info: iBeaconInfo) {
        let beaconRegion = CLBeaconRegion(proximityUUID: self._uuid, major: info.major, minor: info.minor, identifier: "com.villarakavy.hometoucher")
        self._beaconData = (beaconRegion.peripheralData(withMeasuredPower: nil) as NSDictionary) as? [String : Any]
        
        // If possible start advertising the beacon
        self.doActivate()
    }
    
    func deactivate() {
        self._beaconData = nil
        self.doActivate()
    }
}
#endif

