//
//  HomeTouchViewController.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 13.10.2015.
//  Copyright © 2015 Yuval Rakavy. All rights reserved.
//

import Foundation
import UIKit
import CoreLocation
import CoreBluetooth
import PromiseKit

enum HomeTouchControllerError: Error {
    case GetServerOperationAborted
}

class HomeTouchViewController: UIViewController, HomeTouchZoneSelectionDelegate, CLLocationManagerDelegate, GeoSelectDelegate {
    
    @IBOutlet var frameBufferView: FrameBufferView!
    @IBOutlet weak var stateLabel: UILabel!
    
    lazy var model: HomeTouchModel = HomeTouchModel()
    var activeRfbSession: RemoteFrameBufferSession? = nil
    var terminateRfbSessions: (() -> Void)? = nil
    var delayedStateLabel: DelayedLabel? = nil
    
    let homeTouchManagerServiceSelected = PromisedQueue<NetService?>()
    let deviceShaken = PromisedQueue<Bool>()

    let locationManager = CLLocationManager()
    var currentLocation: CLLocation?
    
    var beacon: Beacon?
    
    let showStateLabelAfter: TimeInterval = 2.0
    
    private var zoneSelectionController: HomeTouchZoneSelectionViewController?
    
    var beaconDelegate: BeaconDelegate? { get { return self.beacon }}
    var geoSelectDelegate: GeoSelectDelegate? { get { return self }}
    
    func getRfbServer(cancellationPromise: Promise<Bool>) -> Promise<HostAddress> {
        let ensureHasDefaultHometouchService = model.homeTouchManagerServiceName == nil ?
          self.ensureHasHometouchService() : Promise(value: true)
        
        self.frameBufferView.lowRes = model.lowRes
    
        return ensureHasDefaultHometouchService.then { _ in
            // First the "fast lane" is tried - this assumes that the cached home manager address is valid
            if let homeTouchManagerAddress = self.model.homeTouchManagerServiceAddress {
                self.stateLabel.text = NSLocalizedString("LookingForHomeTouchServer", comment: "")
                return HomeTouchManager(serverAddress: homeTouchManagerAddress,
                                        screenSize: self.frameBufferView.frameBounds.size,
                                        safeAreaInsets: self.frameBufferView.frameSafeAreaInsets).getServer().then { maybeServerAddress in
                    if let serverAddress = maybeServerAddress {
                        return Promise(value: serverAddress)
                    }
                    else {
                        return self.tryGetServerAddress(cancellationPromise: cancellationPromise)
                    }
                }
            }
            else {
                assert(false, "No address for default hometouch server \(self.model.homeTouchManagerServiceName ?? "NO-NAME"))")
                
                return Promise(value: (hostname: "", port: 0))
            }
        }
    }

    func ensureHasHometouchService() -> Promise<Bool> {
        self.selectHomeTouchManager()
        
        return self.homeTouchManagerServiceSelected.wait().then { _ in true }
    }
    
    // Try to query the manager for the rfb server
    //  If not successful it could be that there is not connectivity to the manager
    //  or that the manager address is invalid
    func tryGetServerAddress(cancellationPromise: Promise<Bool>) -> Promise<HostAddress> {
        var hostAddress: HostAddress? = nil
        
        let _ = PromisedLand.doWhile(cancellationPromise: cancellationPromise) { () in
            self.stateLabel.text = NSLocalizedString("LookingForHomeTouchManager", comment: "")
            
            return HomeTouchManagerBrowser(defaultManagerName: self.model.homeTouchManagerServiceName!).findManager().then { mayBeService in
                if hostAddress != nil {
                    return Promise(value: false)        // Found rfb server - no need to browse for manager service
                }
                
                if let service = mayBeService {
                    self.model.add(service: service);   // will update the service address if already exist, or add it as a new one
                    return Promise(value: false)        // Got the service address - no need to keep looking
                }
                else {
                    return after(interval: 5).then { true }
                }
            }
        }
        
        return PromisedLand.doWhile(cancellationPromise: cancellationPromise) { () in
            return HomeTouchManager(serverAddress: self.model.homeTouchManagerServiceAddress!,
                                    screenSize: self.frameBufferView.frameBounds.size,
                                    safeAreaInsets: self.frameBufferView.frameSafeAreaInsets).getServer().then { mayBeHostAddress in
                if let result = mayBeHostAddress {
                    hostAddress = result
                    return Promise(value: false)            // Found host address
                }
                else {
                    return Promise(value: true)             // Keep looking
                }
            }
        }.then { _ in
            if let result = hostAddress {
                return Promise(value: result)
            }
            else {
                throw HomeTouchControllerError.GetServerOperationAborted
            }
        }
    }
    
    func handleRfbSessions(cancellationPromise: Promise<Bool>) -> Promise<Bool> {
        NSLog("Handle RFB sessions")
        
        let _ : Promise<Bool> = cancellationPromise.then { _ in
            if let session = self.activeRfbSession {
                session.terminate()
                self.activeRfbSession = nil
            }
            
            return Promise(value: false)
        }
     
        self.delayedStateLabel?.showAfter(time: self.showStateLabelAfter)
        
        return PromisedLand.doWhile(cancellationPromise: cancellationPromise) { () in
            return self.getRfbServer(cancellationPromise: cancellationPromise).then { serverAddress in
                self.activeRfbSession = RemoteFrameBufferSession(frameBitmapView: self.frameBufferView)
                self.activeRfbSession?.onApiCall = self.dispatchApi
                
                for r in self.activeRfbSession!.getRecognizers() {
                    self.frameBufferView?.addGestureRecognizer(r)
                }
                
                return self.activeRfbSession!.begin(server: serverAddress.hostname, port: serverAddress.port, onSessionStarted: { self.delayedStateLabel?.hide() }).then { _ in
                    NSLog("RFB Session completed")
                    self.activeRfbSession = nil
                    
                    return Promise(value: true)         // Restart another session
                }.recover() { (error) -> Promise<Bool> in
                    NSLog("RFB session terminated with error: \(error)")
                    return Promise(value: true)
                }
            }
        }
    }
    
    func dispatchApi(parameters: [String: String]) {
        NSLog("Api invocation:")
        for (name, value) in parameters {
            NSLog("  \(name) = \(value)")
        }
        
        if let method = parameters["Method"] {
            switch method {
                
            case "ServerVersion":
                if let version = parameters["Version"] {
                    self.activeRfbSession?.serverApiVersion = Int(version)
                    self.activeRfbSession?.invokeApi(parameters: [
                        "Method": "ViewerVersion",
                        "Version": "1",
                        "App": "HomeToucher"
                        ])
                }
                break
                
            default:
                NSLog("Unsupported API call \(parameters["Method"] ?? "NO-METHOD")")
                break
            }
        }
    }
    
    // MARK: HomeTouchZoneSelectionDelegate implementation
    func homeTouchManagerSelectionCanceled() {
        self.dismiss(animated: true, completion: nil)
        self.zoneSelectionController = nil
        homeTouchManagerServiceSelected.send(nil)
    }
    
    func removeHomeTouchManager(name: String) {
        model.remove(serviceName: name)
    }
    
    func changeCurrentHometouchManager(name: String) {
        NSLog("Change to domain \(name)")

        self.model.homeTouchManagerServiceName = name

        let _: Promise<Bool> = HomeTouchManagerBrowser(defaultManagerName: name).findManager().then { theService in
            if let service = theService {
                self.model.add(service: service)
                self.homeTouchManagerServiceSelected.send(service)
            }
            else {
                self.homeTouchManagerServiceSelected.send(nil)
            }
            
            return Promise(value: true)
        }
    }
    
    func reconnect() {
        if let currentServiceName = self.model.homeTouchManagerServiceName {
            self.changeCurrentHometouchManager(name: currentServiceName)
        }
    }

    func selectedHomeTouchManager(name: String) {
        self.dismiss(animated: true, completion: nil)
        self.zoneSelectionController = nil
        self.changeCurrentHometouchManager(name: name)
    }
    
    func selectedHomeTouchManager(service: NetService) {
        selectedHomeTouchManager(name: service.name)
    }
    
    func getHomeTouchManagerNames() -> [String] {
        return [String](model.managerAddresses.keys)
    }
    
    func getCurrentHomeTouchManagerName() -> String? {
        return model.homeTouchManagerServiceName
    }

    func getLocationAuthorizationStatus() -> Bool {
        switch CLLocationManager.authorizationStatus() {
            case .denied, .restricted: return false
            default: return true
        }
    }
    
    func isGeoSelectEnabled() -> Bool {
        return self.getLocationAuthorizationStatus() && self.model.geoSelectEnabled
    }
    
    func changeGeoSelectTo(state: Bool) {
        if CLLocationManager.authorizationStatus() == .notDetermined {
            self.locationManager.requestWhenInUseAuthorization()
        }

        let actualState = state && self.getLocationAuthorizationStatus()
        model.geoSelectEnabled = actualState
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "showZoneSelector" {
            self.zoneSelectionController = segue.destination as? HomeTouchZoneSelectionViewController
            self.zoneSelectionController?.delegate = self
        }
    }
    
    func selectHomeTouchManager() {
        performSegue(withIdentifier: "showZoneSelector", sender: self.frameBufferView)
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        self.zoneSelectionController?.redisplay()
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let lastLocation = locations.last {
            NSLog("Location is \(lastLocation.coordinate)")
        }
        
        self.currentLocation = locations.last
        
        if let currentLocation = self.currentLocation {
            var maybeGeoSelectedDomain: String?
            
            for (domainName, location) in self.model.managerLocations {
                if CLLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude).distance(from: currentLocation) < 500 {
                    maybeGeoSelectedDomain = domainName
                    NSLog("Current location is managed by \(domainName)")
                    break
                }
            }
            
            if let geoSelectedDomain = maybeGeoSelectedDomain, (self.model.lastGeoSelectedDomain == nil || self.model.lastGeoSelectedDomain == self.model.homeTouchManagerServiceName) {
                self.model.lastGeoSelectedDomain = geoSelectedDomain
                
                NSLog("Select new domain \(geoSelectedDomain) - due to location change")
                self.changeCurrentHometouchManager(name: geoSelectedDomain)
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("Location failed with \(error)")
    }
    
    func getGeoDescription(location: CLLocation) -> String? {
        if let currentLocation = self.currentLocation {
            let distanceInMeters = currentLocation.distance(from: location)
            let distance = distanceInMeters > 1000 ? distanceInMeters / 1000 : distanceInMeters
            let units = distanceInMeters > 1000 ? NSLocalizedString("km", comment: "") : NSLocalizedString("meters", comment: "")
            
            return String(format: NSLocalizedString("GeoDescriptionWithDistance", comment: ""), location.coordinate.latitude, location.coordinate.longitude, distance) + units
        }
        else {
            return String(format: NSLocalizedString("GeoDescription", comment: ""), location.coordinate.latitude, location.coordinate.longitude)
        }
    }
    
    func getGeoDescription(name: String) -> String? {
        if let location = self.model.managerLocations[name] {
            return self.getGeoDescription(location: location)
        }
        else {
            return nil
        }
    }
    
    func getGeoDescription(service: NetService) -> String? {
        if let location = self.model.getServiceGeoLocation(service) {
            return self.getGeoDescription(location: location)
        }
        
        return nil
    }
    
    func handleDeviceShaking() {
        _ = PromisedLand.doWhile {
            return self.deviceShaken.wait().then { _ in
                if self.zoneSelectionController == nil {
                    self.selectHomeTouchManager()
                }
                
                return Promise(value: true)
            }
        }
    }
    
    func handleHometouchManagerChange() {
        _ = PromisedLand.doWhile {
            return self.homeTouchManagerServiceSelected.wait().then { service in
                if service != nil {
                    self.activeRfbSession?.terminate()
                }
                
                return Promise<Bool>(value: true)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.beacon = Beacon(uuid: model.beaconUUID)
        
        if model.beaconState {
            self.beacon?.activate(info: model.beaconInfo)
        }
        
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = 100              // 100m accuracy is good enough
        self.locationManager.distanceFilter = 50                // Deliver new location is device is moved by 50m
        
        self.delayedStateLabel = DelayedLabel(label: self.stateLabel!)
        
        self.frameBufferView.deviceShaken = self.deviceShaken
        self.handleDeviceShaking()
        
        
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.locationManager.startUpdatingLocation()
        
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        let abort = PromisedLand.getCancellationPromise()
        self.terminateRfbSessions = abort.cancelFunction
        
        self.handleHometouchManagerChange()
        
        let _ : Promise<Bool> =  self.handleRfbSessions(cancellationPromise: abort.promise).then { _ in
            NSLog("Rfb Sessions terminated")
            return Promise(value: true)
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        self.terminateRfbSessions?()
        self.terminateRfbSessions = nil
    }
}

enum SessionError: Error {
    case InvalidConnection (errorMessage: String)
    case SecurityFailed (errorMessage: String)
}

class DelayedLabel {
    unowned let label: UILabel
    
    private var reject: ((Error) -> Void)?
    
    enum DelayedLabelError: Error, CancellableError {
        case cancel
        
        var isCancelled: Bool { get { return self == .cancel } }
    }
    
    var text: String? { get { return self.label.text } set { self.label.text = newValue } }
    
    init(label: UILabel) {
        self.label = label
    }
    
    func showAfter(time: TimeInterval) {
        let _: Promise<Bool> = Promise<Bool>() { resolve, reject in
            self.reject = reject
            
            let _ = after(interval: time).then {
                resolve(true)
            }
        }.then { _ in
            self.reject = nil
            self.label.isHidden = false
            
            return Promise(value: true)
        }
    }
    
    func hide() {
        self.label.isHidden = true
        
        if let reject = self.reject {
            self.reject = nil
            reject(DelayedLabelError.cancel)
        }
        
    }
}
