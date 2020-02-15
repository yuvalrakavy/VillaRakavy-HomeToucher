//
//  PromiseExtensions.swift
//  HomeToucher2
//
//  Created by Yuval Rakavy on 02/11/2016.
//  Copyright © 2016 Yuval Rakavy. All rights reserved.
//

// Useful Promise functions

import Foundation
import PromiseKit

class PromisedLand {
    // Execute a promise function n times. Return promise that is resolved when the loop is done
    //
    // The body function returns a promise that resolve to true if the loop should continue, or false if the loop
    // should be abored
    //
    public static func loop(_ n: Int, on: DispatchQueue? = conf.Q.map, _ body: @escaping (Int) -> Promise<Bool>) -> Promise<Bool> {
        func doLoop(_ count: Int) -> Promise<Bool> {
            if count == 0 {
                return Promise.value(true)
            }
            else {
                return Promise<Bool>(resolver: { r in
                    body(n-count).done(on: on) { (bodyResult : Bool) in
                        if(bodyResult) {
                            doLoop(count-1).done(on: on) {doLoopResult in r.fulfill(doLoopResult) }.catch { r.reject($0) }
                        }
                        else {
                            r.fulfill(false)
                        }
                    }.catch { r.reject($0) }
                })
            }
        }
       
        return doLoop(n)
    }
    
    public static func iterate<T: Sequence>(_ iteratable: T, on: DispatchQueue? = conf.Q.map, _ body: @escaping (T.Iterator.Element) -> Promise<Bool>) -> Promise<Bool> {
        var iterator = iteratable.makeIterator()
        
        func nextItem() -> Promise<Bool> {
            return Promise<Bool>(resolver: { r in
                if let item = iterator.next() {
                    body(item).done(on: on) {(bodyResult: Bool) in
                        if bodyResult {
                            nextItem().done(on: on) { nextItemResult in r.fulfill(nextItemResult) }.catch {r.reject($0) }
                        }
                        else {
                            r.fulfill(false)
                        }
                    }.catch { r.reject($0)}
                }
            })
        }
        
        return nextItem()
    }
    
    public static func doWhile(_ optionalTitle: String?, on: DispatchQueue? = conf.Q.map, _ body: @escaping () -> Promise<Bool>) -> Promise<Bool> {
        func doIt() -> Promise<Bool> {
            return Promise<Bool>(resolver: { r in
                body().done(on: nil) { (bodyResult : Bool) in
                    if(bodyResult) {
                        doIt().done(on: on) {
                            doItResult in r.fulfill(doItResult)
                        }.catch { r.reject($0) }
                    }
                    else {
                        r.fulfill(true)
                    }
                }.catch { r.reject($0) }
            })
        }

        return doIt()
    }
    
    public static func doWhile(_ optionalTitle: String?, cancellationPromise: Promise<Bool>, _ body: @escaping () -> Promise<Bool>) -> Promise<Bool> {
        return doWhile(optionalTitle) {
            return race(cancellationPromise.then { _ in Promise.value(false) }, body())
        }
    }
    
    
    public static func getCancellationPromise() -> (promise: Promise<Bool>, cancelFunction: () -> Void) {
        var abortFunction:  (() -> Void)? = nil
       
        func setAbortFunction(fulfill: @escaping (Bool) -> Void) {
            abortFunction = { () -> Void in _ = fulfill(false) }
        }
        
        let cancellationPromise = Promise<Bool> { seal in setAbortFunction(fulfill: seal.fulfill) }
        
        return (promise: cancellationPromise, cancelFunction: abortFunction! )
    }
}
