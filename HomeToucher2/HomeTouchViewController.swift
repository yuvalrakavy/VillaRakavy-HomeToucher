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

enum HomeTouchControllerError: Error {
    case GetServerOperationAborted
}

@MainActor
class HomeTouchViewController: UIViewController, @MainActor HomeTouchZoneSelectionDelegate, @MainActor GeoSelectDelegate, @MainActor CLLocationManagerDelegate {
    
    @IBOutlet var frameBufferView: FrameBufferView!
    @IBOutlet weak var stateLabel: UILabel!
    
    lazy var model: HomeTouchModel = HomeTouchModel()
    var activeRfbSession: RemoteFrameBufferSession? = nil
    var terminateRfbSessions: (() -> Void)? = nil
    var rfbTask: Task<Void, Never>? = nil
    var delayedStateLabel: DelayedLabel? = nil
    
    let homeTouchManagerServiceSelected = PromisedQueue<NetService?>("service-selected")
    let deviceShaken = PromisedQueue<Bool>("device-shaken")

    let locationManager = CLLocationManager()
    var locationAutherizationStatus: CLAuthorizationStatus

    var currentLocation: CLLocation?
    
    let cacheManager: CacheManager
    
    #if BL_BEACON
    var beacon: Beacon?
    var beaconDelegate: BeaconDelegate? { get { return self.beacon }}
    #endif
    
    let showStateLabelAfter: TimeInterval = 2.0
    
    private var zoneSelectionController: HomeTouchZoneSelectionViewController?
    
    var geoSelectDelegate: GeoSelectDelegate? { get { return self }}
    
    required init?(coder: NSCoder) {
        do {
            self.cacheManager = try CacheManager()
        } catch {
            NSLog("Error while initializing cache manager \(error)")
            fatalError()
        }
        
        self.locationAutherizationStatus = .notDetermined
        super.init(coder: coder)
    }
        
    func getRfbServer(isCancelled: @escaping () async -> Bool) async throws -> HostAddress {
        if model.homeTouchManagerServiceName == nil {
            _ = await self.ensureHasHometouchService()
        }

        self.frameBufferView.lowRes = model.lowRes

        if model.useSpecificServer, let specificServerName = model.specificServerName {
            return (specificServerName, model.specificServerPort)
        }

        if let homeTouchManagerAddress = self.model.homeTouchManagerServiceAddress {
            self.stateLabel.text = NSLocalizedString("LookingForHomeTouchServer", comment: "")
            let manager = HomeTouchManager(
                serverAddress: homeTouchManagerAddress,
                screenSize: self.frameBufferView.frameBounds.size,
                safeAreaInsets: self.frameBufferView.frameSafeAreaInsets
            )
            if let serverAddress = await manager.getServer() {
                return serverAddress
            } else {
                return try await self.getServerAddressWithRetry(isCancelled: isCancelled)
            }
        } else {
            assert(false, "No address for default hometouch server \(self.model.homeTouchManagerServiceName ?? "NO-NAME")")
            return (hostname: "", port: 0)
        }
    }
    
    private func getServerAddressWithRetry(isCancelled: @escaping () async -> Bool) async throws -> HostAddress {
        var hostAddress: HostAddress? = nil

        func setService(_ mayBeService: NetService?) async -> Bool {
            if hostAddress != nil { return false }
            if let service = mayBeService {
                self.model.add(service: service)
                return false
            } else {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return true
            }
        }

        while !(await isCancelled()) {
            self.stateLabel.text = NSLocalizedString("LookingForHomeTouchManager", comment: "")
            let mayBeService = await HomeTouchManagerBrowser(defaultManagerName: self.model.homeTouchManagerServiceName!).findManager()
            let shouldContinue = await setService(mayBeService)
            if !shouldContinue { break }
        }

        while !(await isCancelled()) {
            if let addr = self.model.homeTouchManagerServiceAddress {
                let maybeHostAddress = await HomeTouchManager(
                    serverAddress: addr,
                    screenSize: self.frameBufferView.frameBounds.size,
                    safeAreaInsets: self.frameBufferView.frameSafeAreaInsets
                ).getServer()
                if let result = maybeHostAddress {
                    hostAddress = result
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        if let result = hostAddress {
            return result
        } else {
            throw HomeTouchControllerError.GetServerOperationAborted
        }
    }
    
    func ensureHasHometouchService() async -> Bool {
        self.selectHomeTouchManager()
        _ = try? await self.homeTouchManagerServiceSelected.wait()
        return true
    }
    
    func handleRfbSessions(isCancelled: @escaping () async -> Bool) async {
        self.delayedStateLabel?.showAfter(time: self.showStateLabelAfter)

        while true {
            if Task.isCancelled { break }
            if await isCancelled() { break }

            func doTheSession(_ serverAddress: HostAddress) async {
                self.activeRfbSession = RemoteFrameBufferSession(model: self.model, frameBitmapView: self.frameBufferView, cacheManager: self.cacheManager)
                self.activeRfbSession?.onApiCall = self.dispatchApi

                for r in self.activeRfbSession!.getRecognizers() {
                    self.frameBufferView?.addGestureRecognizer(r)
                }

                do {
                    _ = try await self.activeRfbSession!.begin(server: serverAddress.hostname, port: serverAddress.port, onSessionStarted: { self.delayedStateLabel?.hide() })
                    NSLog("RFB Session completed")
                    self.activeRfbSession = nil
                } catch {
                    NSLog("RFB session terminated with error: \(error)")
                    self.activeRfbSession = nil
                }
            }

            do {
                let serverAddress = try await self.getRfbServer(isCancelled: isCancelled)
                await doTheSession(serverAddress)
            } catch {
                NSLog("Failed to get server: \(error)")
                // continue loop and try again
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
    
    func changeCurrentHomeTouchManager(name: String) {
        self.model.homeTouchManagerServiceName = name

        Task { @MainActor in
            let theService = await HomeTouchManagerBrowser(defaultManagerName: name).findManager()
            if let service = theService {
                self.model.add(service: service)
                self.homeTouchManagerServiceSelected.send(service)
            } else {
                self.homeTouchManagerServiceSelected.send(nil)
            }
        }
    }
    
    func reconnect() {
        if let currentServiceName = self.model.homeTouchManagerServiceName {
            self.changeCurrentHomeTouchManager(name: currentServiceName)
        }
    }

    func selectedHomeTouchManager(name: String, dismiss: Bool) {
        if dismiss {
            self.dismiss(animated: true, completion: nil)
        }
        self.zoneSelectionController = nil
        self.changeCurrentHomeTouchManager(name: name)
    }
    
    func selectedHomeTouchManager(service: NetService) {
        selectedHomeTouchManager(name: service.name, dismiss: true)
    }
    
    func getHomeTouchManagerNames() -> [String] {
        return [String](model.managerAddresses.keys)
    }
    
    func getCurrentHomeTouchManagerName() -> String? {
        return model.homeTouchManagerServiceName
    }

    func getLocationAuthorizationStatus() -> Bool {
        switch self.locationAutherizationStatus {
            case .denied, .restricted: return false
            default: return true
        }
    }
    
    func isGeoSelectEnabled() -> Bool {
        return self.getLocationAuthorizationStatus() && self.model.geoSelectEnabled
    }
    
    func changeGeoSelectTo(state: Bool) {
        if self.locationAutherizationStatus == .notDetermined {
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
    
    func handleDeviceShaking() {
        Task { @MainActor in
            while true {
                do {
                    _ = try await self.deviceShaken.wait()
                    if self.zoneSelectionController == nil {
                        self.selectHomeTouchManager()
                    }
                } catch {
                    break
                }
            }
        }
    }
    
    func handleHometouchManagerChange() {
        Task { @MainActor in
            while true {
                do {
                    let service = try await self.homeTouchManagerServiceSelected.wait()
                    if service != nil || self.model.useSpecificServer {
                        self.activeRfbSession?.terminate()
                    }
                } catch {
                    break
                }
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        #if BL_BEACON
        self.beacon = Beacon(uuid: model.beaconUUID)
        
        if model.beaconState {
            self.beacon?.activate(info: model.beaconInfo)
        }
        #endif
        
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = 100              // 100m accuracy is good enough
        self.locationManager.distanceFilter = 50                // Deliver new location is device is moved by 50m
        
        self.delayedStateLabel = DelayedLabel(label: self.stateLabel!)
        self.stateLabel.isHidden = true
        
        self.frameBufferView.deviceShaken = self.deviceShaken
        self.handleDeviceShaking()
        
        
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.locationManager.startUpdatingLocation()
        
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.handleHometouchManagerChange()
        
        self.rfbTask = Task { [weak self] in
            guard let self else { return }
            await self.handleRfbSessions(isCancelled: { Task.isCancelled })
            NSLog("Rfb Sessions terminated")
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        self.terminateRfbSessions?()
        self.terminateRfbSessions = nil
        self.rfbTask?.cancel()
        self.rfbTask = nil
    }
}

extension HomeTouchViewController {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.locationAutherizationStatus = manager.authorizationStatus
            self.zoneSelectionController?.redisplay()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
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

                if let geoSelectedDomain = maybeGeoSelectedDomain, (self.model.lastGeoSelectedDomain == nil || self.model.lastGeoSelectedDomain != self.model.homeTouchManagerServiceName) {
                    self.model.lastGeoSelectedDomain = geoSelectedDomain

                    NSLog("Select new domain \(geoSelectedDomain) - due to location change")
                    self.changeCurrentHomeTouchManager(name: geoSelectedDomain)
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            NSLog("Location failed with \(error)")
        }
    }
}

enum SessionError: Error {
    case InvalidConnection (errorMessage: String)
    case SecurityFailed (errorMessage: String)
}

private enum DelayedLabelCancellation: Error { case cancelled }

class DelayedLabel {
    unowned let label: UILabel
    private var task: Task<Void, Never>?

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    init(label: UILabel) {
        self.label = label
    }

    func showAfter(time: TimeInterval) {
        // Cancel any previous task
        task?.cancel()
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(time * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.label.isHidden = false
            } catch {
                // sleep can throw CancellationError; ignore
            }
        }
    }

    func hide() {
        label.isHidden = true
        task?.cancel()
        task = nil
    }
}

