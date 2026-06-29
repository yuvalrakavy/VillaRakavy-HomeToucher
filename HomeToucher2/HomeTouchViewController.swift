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
        self.frameBufferView.lowRes = model.lowRes

        // Specific-server mode: connect directly to a user-entered host[:port].
        if model.useSpecificServer {
            // `specificServerName` returns "" (not nil) for a blank address, so an
            // emptiness/whitespace check is required: connecting to an empty host
            // previously crashed (or spun) the moment the user enabled the switch
            // before typing a valid address.
            let host = (model.specificServerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // A usable host is a non-empty IPv4 address or DNS hostname: ASCII
            // letters/digits/dot/hyphen only. This rejects leftover garbage (e.g.
            // non-ASCII text) so it's treated as "no address" instead of being
            // retried forever.
            let hostAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
            let hostIsValid = !host.isEmpty && host.unicodeScalars.allSatisfy { hostAllowed.contains($0) }
            if hostIsValid {
                return (host, model.specificServerPort)
            } else {
                // No usable address. Surface the selector (once) so the user can type
                // one or turn the option off, then wait and let the loop re-read the
                // setting on the next iteration. Self-heals; no crash, no busy-loop.
                NSLog("Specific server is enabled but no valid address; prompting for configuration")
                self.stateLabel.text = NSLocalizedString("LookingForHomeTouchServer", comment: "")
                if self.zoneSelectionController == nil {
                    self.selectHomeTouchManager()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                throw HomeTouchControllerError.GetServerOperationAborted
            }
        }

        if model.homeTouchManagerServiceName == nil {
            // No zone chosen yet: present the selector and retry once the user picks
            // one. Do NOT consume the selection signal here — handleHometouchManagerChange
            // is the single consumer (a second consumer would fight it for the
            // AsyncStream's one iterator). The loop re-reads the chosen name next pass.
            NSLog("No zone selected; prompting for one")
            self.stateLabel.text = NSLocalizedString("LookingForHomeTouchManager", comment: "")
            if self.zoneSelectionController == nil {
                self.selectHomeTouchManager()
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            throw HomeTouchControllerError.GetServerOperationAborted
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
            // No manager address available. Abort this attempt cleanly and let the loop
            // retry (was: assert(false) → trap in debug / bogus ("",0) connect in release).
            NSLog("No address for hometouch server \(self.model.homeTouchManagerServiceName ?? "NO-NAME")")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            throw HomeTouchControllerError.GetServerOperationAborted
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
    
    func handleRfbSessions(isCancelled: @escaping () async -> Bool) async {
        self.delayedStateLabel?.showAfter(time: self.showStateLabelAfter)

        while true {
            if Task.isCancelled { break }
            if await isCancelled() { break }

            func doTheSession(_ serverAddress: HostAddress) async {
                self.activeRfbSession = RemoteFrameBufferSession(model: self.model, frameBitmapView: self.frameBufferView, cacheManager: self.cacheManager)
                self.activeRfbSession?.onApiCall = self.dispatchApi

                // Remove any recognizers left by a previous session before adding
                // this session's, so they don't accumulate on the view across the
                // reconnect loop.
                if let existing = self.frameBufferView?.gestureRecognizers {
                    for r in existing { self.frameBufferView?.removeGestureRecognizer(r) }
                }
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
                    // Back off before the caller retries, so a persistently-failing
                    // connection (unreachable / invalid host) cannot busy-loop and
                    // drain CPU/battery.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
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
        // Picking a zone is the explicit "use this zone" choice and is mutually
        // exclusive with direct-connect: turn off useSpecificServer so the session
        // loop stops taking the (possibly invalid) specific-server branch and
        // re-prompting. Set synchronously, before the async reconnect below.
        self.model.useSpecificServer = false

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
            // Single, long-lived consumer of the selection signal. PromisedQueue.wait()
            // is now cancellation-safe and delivers every value in order, so a loop of
            // wait() correctly receives each selection. Terminating the active session
            // makes the session loop reconnect to the newly-chosen zone.
            while true {
                do {
                    let service = try await self.homeTouchManagerServiceSelected.wait()
                    if service != nil || self.model.useSpecificServer {
                        self.activeRfbSession?.terminate()
                    }
                } catch {
                    break   // queue finished
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

        // Actually tear the session down. Cancelling rfbTask alone does NOT stop the
        // session: its sessionTask/pingTask are unstructured and don't inherit
        // cancellation, so without an explicit terminate() the session, socket, and
        // 5-minute ping kept running in the background after leaving the screen.
        self.activeRfbSession?.terminate()
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

