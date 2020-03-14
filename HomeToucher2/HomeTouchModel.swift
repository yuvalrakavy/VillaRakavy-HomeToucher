//
//  HomeTouchModel.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 12.10.2015.
//  Copyright © 2015 Yuval Rakavy. All rights reserved.
//

import Foundation
import UIKit
import CoreLocation

let ServiceNameKey = "HomeTouchManagerServiceName"
let ManagerAddressesKey = "HomeTouchManagers"
let ManagerLocationslongitudeKey = "HomeTouchManagerlongitudes"
let ManagerLocationsLatitudeKey = "HomeTouchManagerLatitudes"
let geoSelectEnabledKey = "GeoSelectEnabled"
let beaconStateKey = "BeaconState"
let beaconMajorKey = "BeaconMajor"
let beaconMinorKey = "BeaconMinor"
let disableCachingKey = "DisableCaching"
let useSpecificServerKey = "UseSpecificServer"
let specificServerAddressKey = "SpecificServerAddress"

public typealias GeoLocation = (longitude: Double, latitude: Double)
public typealias iBeaconInfo = (major: UInt16, minor: UInt16)

public class HomeTouchModel {
    public var homeTouchManagerServiceName: String? {
        willSet(serviceName) {
            if serviceName != homeTouchManagerServiceName {
                let store = UserDefaults();
                
                store.setValue(serviceName, forKey: ServiceNameKey);
                store.synchronize()
            }
        }
    }
    
    private var _geoSelectEnabled: Bool?
    
    public var geoSelectEnabled: Bool {
        get {
            if let result = self._geoSelectEnabled {
                return result
            }
            else {
                self._geoSelectEnabled = UserDefaults().bool(forKey: geoSelectEnabledKey)
                return self._geoSelectEnabled ?? false
            }
        }

        set {
            if newValue != self._geoSelectEnabled {
                let store = UserDefaults()
                
                self._geoSelectEnabled = newValue
                store.setValue(newValue, forKey: geoSelectEnabledKey)
                store.synchronize()
            }
        }
    }

    private var _disableCaching: Bool?
    
    public var DisableCaching: Bool {
        get {
            if let result = self._disableCaching {
                return result
            }
            else {
                self._disableCaching = UserDefaults().bool(forKey: disableCachingKey)
                return self._disableCaching ?? false
            }
        }
        
        set {
            if newValue != self._disableCaching {
                let store = UserDefaults()
                
                self._disableCaching = newValue
                store.setValue(newValue, forKey: disableCachingKey)
                store.synchronize()
            }
        }
    }
    
    public var lastGeoSelectedDomain: String?

    // If lowRes is true, then the resolution is in points and not pixel, e.g. on retina display the bitmaps will be
    // qouter (if x2) or one ninth of the size (in case of x3), this should yield a much quicker operation with reduced
    // display resoltion
    //
    public var lowRes: Bool {
        get { return false }
    }
    
    public var homeTouchManagerServiceAddress: Data? {
        get {
            return self.homeTouchManagerServiceName != nil ? self.managerAddresses[self.homeTouchManagerServiceName!] : nil
        }
    }
    
    public var managerAddresses: [String: Data]
    
    public var managerLocations: [String: CLLocation]
    
    
    private var _useSpecificServer: Bool?
    
    public var useSpecificServer: Bool {
        get {
            if let r = _useSpecificServer {
                return r
            }
            else {
                self._useSpecificServer = UserDefaults().bool(forKey: useSpecificServerKey)
                return self._useSpecificServer ?? false
            }
        }
        
        set {
            if newValue != self._useSpecificServer {
                let store = UserDefaults()
                
                self._useSpecificServer = newValue
                store.setValue(newValue, forKey: useSpecificServerKey)
                store.synchronize()
            }
        }
    }
    
    private var _specificServerAddress : String?
    
    public var specificServerAddress : String? {
        get {
            if(_specificServerAddress == nil) {
                self._specificServerAddress = UserDefaults().string(forKey: specificServerAddressKey)
            }
            return self._specificServerAddress
        }
        
        set {
            if newValue != self._specificServerAddress {
                let store = UserDefaults()
                
                self._specificServerAddress = newValue
                
                if let v = newValue {
                    store.setValue(v, forKey: specificServerAddressKey)
                }
                else {
                    store.removeObject(forKey: specificServerAddressKey)
                }
                
                store.synchronize()
            }
        }
    }
    
    public var specificServerName: String? {
        get {
            if let a = self.specificServerAddress {
                let columnIndex = a.firstIndex(of: ":") ?? a.endIndex
                
                return String(a[..<columnIndex])
            }
            else {
                return nil
            }
        }
    }
    
    public var specificServerPort: Int {
        get {
            if let a = self.specificServerAddress, let columnIndex = a.firstIndex(of: ":") {
                return Int(a[a.index(columnIndex, offsetBy: 1) ..< a.endIndex]) ?? 5900
            }
            else {
                return 5900             // Default port
            }
        }
    }
    
    init() {
        let store = UserDefaults();
        
        homeTouchManagerServiceName = store.string(forKey: ServiceNameKey);
        
        if let managers = store.dictionary(forKey: ManagerAddressesKey) as? [String: Data] {
            self.managerAddresses = managers;
        }
        else {
            self.managerAddresses = [String: Data]();
        }
        
        self.managerLocations = [String: CLLocation]()
        
        if let longitudes = store.dictionary(forKey: ManagerLocationslongitudeKey) as? [String: Double],
           let latitudes = store.dictionary(forKey: ManagerLocationsLatitudeKey) as? [String: Double] {
            
            for (name, _) in longitudes {
                self.managerLocations[name] = CLLocation(latitude: latitudes[name]!, longitude: longitudes[name]!)
            }
        }
        
        self.defineShortcuts()
    }
    
    static func decode<T>(data: Data) -> T {
        return data.withUnsafeBytes { $0.load(as: T.self)}
    }
    
    struct AddressInfo {
        var length: UInt8
        var family: UInt8
    }
    
    static func getDestinationIpV4address(homeTouchManagerService: NetService) -> Data? {
        if let addresses = homeTouchManagerService.addresses {
            for addressData in addresses {
                let addressInfo: AddressInfo = HomeTouchModel.decode(data: addressData)
                //let addr: sockaddr_storage = HomeTouchModel.decode(data: addressData)
                
                if addressInfo.family == UInt8(AF_INET) {
                    return addressData;
                }
            }
        }
        
        return nil;
    }
    
    private var _beaconState: Bool?
    private var _beaconInfo: iBeaconInfo?
    
    private func loadBeaconInfo<R>(_ result: () -> R) -> R {
        let store = UserDefaults()
        
        self._beaconState = store.bool(forKey: beaconStateKey)
        self._beaconInfo = (UInt16(store.integer(forKey: beaconMajorKey)), UInt16(store.integer(forKey: beaconMinorKey)))
        return result()
    }
    
    private func storeBeaconInfo(_ value: Any, forKey: String) {
        let store = UserDefaults()
        store.setValue(value, forKey: beaconStateKey)
        store.synchronize()
    }
    
    public let beaconUUID = UUID(uuidString:"D81B3C4A-5D8B-42FD-9EAA-86341A5590D4")!
    
    public var beaconState: Bool {
        get { return self._beaconState ?? self.loadBeaconInfo { () in self._beaconState! } }
        
        set {	
            self._beaconState = newValue
            self.storeBeaconInfo(newValue, forKey: beaconStateKey)
        }
    }
 
    public var beaconInfo: iBeaconInfo {
        get { return self._beaconInfo ?? self.loadBeaconInfo { () in self._beaconInfo! } }
        
        set {
            self._beaconInfo = newValue
            
            let store = UserDefaults()
            store.setValue(newValue.major, forKey: beaconMajorKey)
            store.setValue(newValue.minor, forKey: beaconMinorKey)
            store.synchronize()
        }
    }
    
    public func add(service: NetService) {
        let store = UserDefaults()
        var modified = false
        
        if let address = HomeTouchModel.getDestinationIpV4address(homeTouchManagerService: service) {
            if let existingServiceAddress = self.managerAddresses[service.name], address == existingServiceAddress {
                // Do nothing since the service is already there
            }
            else {
                self.managerAddresses[service.name] = address
                store.setValue(self.managerAddresses, forKey: ManagerAddressesKey)
                modified = true
            }
        }
        
        if let geoLocation = self.getServiceGeoLocation(service) {
            self.managerLocations[service.name] = geoLocation
            self.storeLocations(store)
            modified = true
        }
        
        if modified {
            store.synchronize()
            self.defineShortcuts()
        }
    }
    
    public func getServiceGeoLocation(_ service: NetService) -> CLLocation? {
        if let txtRecordData = service.txtRecordData() {
            let txtRecord = NetService.dictionary(fromTXTRecord: txtRecordData)
            
            if let longitudeData = txtRecord["longitude"], let latitudeData = txtRecord["latitude"],
                let longitudeString = String(bytes: longitudeData, encoding: String.Encoding.utf8),
                let latitudeString = String(bytes: latitudeData, encoding: String.Encoding.utf8),
                let longitude = Double(longitudeString),
                let latitude = Double(latitudeString)
            {
                return CLLocation(latitude: latitude, longitude: longitude)
            }
        }
        
        return nil
    }
    
    private func storeLocations(_ store: UserDefaults) {
        var longitudes = [String: Double]()
        var latitudes = [String: Double]()
        
        self.managerLocations.forEach { (name, location) in
            longitudes[name] = location.coordinate.longitude
            latitudes[name] = location.coordinate.latitude
        }
        
        store.setValue(longitudes, forKey: ManagerLocationslongitudeKey)
        store.setValue(latitudes, forKey:ManagerLocationsLatitudeKey)
    }
    
    public func remove(serviceName: String) {
        let store = UserDefaults()
        var modified = false
        
        if let _ = self.managerAddresses.removeValue(forKey: serviceName) {
            if serviceName == self.homeTouchManagerServiceName {
                self.homeTouchManagerServiceName = nil
                modified = true
            }
            
            store.setValue(self.managerAddresses, forKey: ManagerAddressesKey)
            modified = true
        }
        
        if let _ = self.managerLocations.removeValue(forKey: serviceName) {
            self.storeLocations(store)
            modified = true
        }
        
        if modified {
            store.synchronize()
            self.defineShortcuts()
        }
    }
    
    public func defineShortcuts() {
        if UIApplication.shared.shortcutItems != nil {
            var shortcuts : [UIApplicationShortcutItem] = []
            
            for (name, _) in self.managerAddresses {
                shortcuts.append(UIApplicationShortcutItem(type: "HomeTouchManager", localizedTitle: name))
            }
            
            UIApplication.shared.shortcutItems = shortcuts
        }
    }
}
