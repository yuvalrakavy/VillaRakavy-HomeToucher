//
//  HomeTouchZoneSelectionControllerViewController.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 12.10.2015.
//  Copyright © 2015 Yuval Rakavy. All rights reserved.
//

import Foundation
import UIKit
import PromiseKit

public protocol GeoSelectDelegate {
    func isGeoSelectEnabled() -> Bool
    func changeGeoSelectTo(state: Bool)
    func getLocationAuthorizationStatus() -> Bool
}


public typealias ZoneInfo = (name: String, geoDescription: String?)

public protocol HomeTouchZoneSelectionDelegate {
    var geoSelectDelegate: GeoSelectDelegate? { get }
    var beaconDelegate: BeaconDelegate? { get }
    
    var model : HomeTouchModel { get }
    func selectedHomeTouchManager(service: NetService)
    func selectedHomeTouchManager(name: String)
    func removeHomeTouchManager(name: String)
    func homeTouchManagerSelectionCanceled()
    
    func getHomeTouchManagerNames() -> [String]
    func getCurrentHomeTouchManagerName() -> String?
    func getGeoDescription(service: NetService) -> String?
    func getGeoDescription(name: String) -> String?
}

struct ListEntry {
    let info: ZoneInfo
    var service: NetService?
    
    init(info: ZoneInfo, service: NetService) {
        self.init(info: info)
        self.service = service
    }
    
    init(info: ZoneInfo) {
        self.info = info
    }
}

public class HomeTouchZoneSelectionViewController : UIViewController, NetServiceBrowserDelegate, UITableViewDataSource, UITableViewDelegate {
    
    var delegate: HomeTouchZoneSelectionDelegate?
    
    var list: [ListEntry] = []
    var newServices: [NetService] = []
    var serviceBrowser: NetServiceBrowser?
    
    @IBOutlet weak var homeTouchManagerServiceTable: UITableView?
    @IBOutlet weak var theTitle: UINavigationItem?
    @IBOutlet weak var editButton: UIBarButtonItem?
    @IBOutlet weak var navigationBar: UINavigationBar!
    @IBOutlet weak var backButton: UIBarButtonItem!
    
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if !self.list.contains(where: {entry in entry.info.name == service.name }) {
            newServices.append(service)
        }
        
        if(!moreComing) {
            let _ : Promise<Bool> = when(resolved: self.newServices.map { (service) -> Promise<Bool> in
                ServiceAddressResolver().resolveServiceAddress(service: service).then { mayBeResolvedService in
                    if let resolvedService = mayBeResolvedService {
                        self.list.append(ListEntry(info: (name: service.name, geoDescription: self.delegate?.getGeoDescription(service: resolvedService)), service: resolvedService))
                    }
                    return Promise(value: true)
                }
            }).then {_ in 
                self.homeTouchManagerServiceTable!.reloadData()
                return Promise(value: true)
            }
        }
    }
    
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        if let index = list.index(where: { entry in entry.info.name == service.name }) {
            list.remove(at: index)
        }
        
        if !moreComing {
            homeTouchManagerServiceTable!.reloadData()
        }
    }
    
    public func numberOfSections(in tableView: UITableView) -> Int {
        return 3
    }
    
    public func tableView(_: UITableView, numberOfRowsInSection: Int) -> Int {
        if numberOfRowsInSection == 0 {
            return list.count
        }
        else {
            return 1
        }
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let entry = list[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: entry.info.geoDescription != nil ? "GeoZoneEntry" : "ZoneEntry") as? ZoneEntry
            
            if cell != nil {
                cell!.selectedCheckmark.text = entry.info.name == delegate?.getCurrentHomeTouchManagerName() ? "✓" : ""
                cell!.name.text = entry.info.name
                
                if let geoDescription = entry.info.geoDescription {
                    let geoCell = cell as! GeoZoneEntry
                    
                    geoCell.geoDescription.text = geoDescription
                }
            }
            
            return cell!
        }
        else if indexPath.section == 1 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "geoEnable") as? GeoSelectCell
            
            cell?.delegate = self.delegate?.geoSelectDelegate
            cell?.update()
            return cell!
        }
        else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "iBeacon") as? iBeaconCell
            
            if let delegate = self.delegate, let beaconDelegate = delegate.beaconDelegate {
                cell?.setup(delegate: beaconDelegate, model: delegate.model)
            }
            
            return cell!
        }
    }
    
    public func tableView(_: UITableView, commit editingStyle: UITableViewCellEditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == UITableViewCellEditingStyle.delete && indexPath.section == 0 {
            delegate?.removeHomeTouchManager(name: list[indexPath.row].info.name)
            list.remove(at: indexPath.row)
            homeTouchManagerServiceTable?.deleteRows(at: [indexPath], with: UITableViewRowAnimation.automatic)
        }
    }
    
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.section == 0 {
            let entry = list[indexPath.row]
            
            if let service = entry.service {
                self.delegate?.selectedHomeTouchManager(service: service)
            }
            else {
                self.delegate?.selectedHomeTouchManager(name: entry.info.name)
            }
        }
    }
    
    public func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return indexPath.section == 0
    }
    
    @IBAction func cancelPressed(_ sender: Any) {
        self.delegate?.homeTouchManagerSelectionCanceled()
    }
    
    @IBAction func editPressed(_ sender: Any) {
        if let tableView = homeTouchManagerServiceTable {
            tableView.isEditing = !tableView.isEditing
            
            if tableView.isEditing {
                navigationBar.topItem?.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(editPressed(_:)))
            }
            else {
                navigationBar.topItem?.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .edit, target: self, action: #selector(editPressed(_:)))
            }
        }
    }
    
    public func redisplay() {
        self.homeTouchManagerServiceTable?.beginUpdates()
        self.homeTouchManagerServiceTable?.reloadRows(at: [IndexPath(row: 0, section: 1)], with: .none)
        self.homeTouchManagerServiceTable?.endUpdates()
    }
    
    public override func viewDidLoad() {
        theTitle?.title = NSLocalizedString("SelectHomeTouchManagerTitle", comment: "")
        homeTouchManagerServiceTable?.dataSource = self
        homeTouchManagerServiceTable?.delegate = self
        
        serviceBrowser = NetServiceBrowser()
        
        if let names = delegate?.getHomeTouchManagerNames() {
            for name in names {
                list.append(ListEntry(info: (name: name, geoDescription: self.delegate?.getGeoDescription(name: name))))
            }
        }
        
        serviceBrowser?.delegate = self
        serviceBrowser?.searchForServices(ofType: "_HtVncConf._udp", inDomain: "")
        
        if self.delegate?.getCurrentHomeTouchManagerName() == nil {
            backButton.isEnabled = false
        }
    }
    
    public override func viewDidDisappear(_ animated: Bool) {
        self.delegate = nil
        homeTouchManagerServiceTable?.dataSource = nil
        homeTouchManagerServiceTable?.delegate = nil
        serviceBrowser?.delegate = nil
    }
}

public class ZoneEntry : UITableViewCell {
    
    @IBOutlet weak var selectedCheckmark: UILabel!
    @IBOutlet weak var name: UILabel!
}

public class GeoZoneEntry : ZoneEntry {
    @IBOutlet weak var geoDescription: UILabel!
    
}

public class GeoSelectCell : UITableViewCell {
    var delegate: GeoSelectDelegate?
    
    @IBOutlet weak var label: UILabel!
    @IBOutlet weak var geoSelectSwitch: UISwitch!
    
    @IBAction func geoSelectEnabled(_ sender: Any) {
        delegate?.changeGeoSelectTo(state: self.geoSelectSwitch.isOn)
        self.update()
    }
    
    func update() {
        self.geoSelectSwitch.isEnabled = self.delegate?.getLocationAuthorizationStatus() ?? false
        self.label.isEnabled = self.delegate?.getLocationAuthorizationStatus() ?? false
        self.geoSelectSwitch.isOn = self.delegate?.isGeoSelectEnabled() ?? false
    }
}

public class iBeaconCell : UITableViewCell {
    var model: HomeTouchModel?
    
    var delegate: BeaconDelegate?
    
    func setup(delegate: BeaconDelegate, model: HomeTouchModel) {
        self.delegate = delegate
        self.model = model
        
        let info = model.beaconInfo
        
        self.majorTextField.text = String(info.major)
        self.minorTextField.text = String(info.minor)
        
        if model.beaconState && delegate.canBeActivated {
            iBeaconSwitch.isOn = true
        }
        else {
            iBeaconSwitch.isOn = false
        }
    }
    
    @IBOutlet weak var iBeaconSwitch: UISwitch!
    
    @IBOutlet weak var majorLabel: UILabel!
    @IBOutlet weak var majorTextField: UITextField!
    @IBOutlet weak var minorLabel: UILabel!
    @IBOutlet weak var minorTextField: UITextField!
    
    @IBAction func beaconStateChanged(_ sender: Any) {
        if self.iBeaconSwitch.isOn {
            guard let major = UInt16(self.majorTextField.text ?? "") else {
                showAlert("InvalidBeaconMajor")
                self.iBeaconSwitch.setOn(false, animated: true)
                return
            }
            
            guard let minor = UInt16(self.minorTextField.text ?? "") else {
                showAlert("InvalidBeaconMinor")
                self.iBeaconSwitch.setOn(false, animated: true)
                return
            }
            
            guard self.delegate?.canBeActivated ?? false else {
                showAlert("BluetoothNotActive")
                self.iBeaconSwitch.setOn(false, animated: true)
                return
            }
            
            NSLog("Enabling iBeacon with: major: \(major) minor: \(minor)")
            
            self.majorLabel.isEnabled = false
            self.majorTextField.isEnabled = false
            self.minorLabel.isEnabled = false
            self.minorTextField.isEnabled = false
            
            self.model?.beaconState = true
            self.delegate?.activate(info: iBeaconInfo(major, minor))
        }
        else {
            self.majorLabel.isEnabled = true
            self.majorTextField.isEnabled = true
            self.minorLabel.isEnabled = true
            self.minorTextField.isEnabled = true

            self.model?.beaconState = false
            self.delegate?.deactivate()
        }
    }
    
    func showAlert(_ messageId: String) {
        func getViewController() -> UIViewController? {
            var responder: UIResponder? = self
            
            while responder != nil {
                if responder is UIViewController {
                    return responder as? UIViewController
                }
                
                responder = responder?.next
            }
            
            return nil
        }
        
        let title = NSLocalizedString(messageId + "Title", comment: "")
        let message = NSLocalizedString(messageId + "Message", comment: "")
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        
        getViewController()?.present(alert, animated: true, completion: nil)
    }
}
