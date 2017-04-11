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
    public static func loop(_ n: Int, _ body: @escaping (Int) -> Promise<Bool>) -> Promise<Bool> {
        func doLoop(_ count: Int) -> Promise<Bool> {
            return count == 0 ? Promise(value: true) : body(n - count).then { $0 ? doLoop(count-1) : Promise(value: false) }
        }
       
        return doLoop(n)
    }
    
    public static func iterate<T: Sequence>(_ iteratable: T, _ body: @escaping (T.Iterator.Element) -> Promise<Bool>) -> Promise<Bool> {
        var iterator = iteratable.makeIterator()
        
        func nextItem() -> Promise<Bool> {
            if let item = iterator.next() {
                return body(item).then { $0 ? nextItem() : Promise(value: false) }
            }
            else {
                return Promise<Bool>(value: true)               // loop was completed
            }
        }
        
        return nextItem()
    }
    
    public static func doWhile(_ body: @escaping () -> Promise<Bool>) -> Promise<Bool> {
        func doIt() -> Promise<Bool> {
            return body().then { $0 ? doIt() : Promise(value: true) }
        }

        return doIt()
    }
    
    public static func doWhile(cancellationPromise: Promise<Bool>, _ body: @escaping () -> Promise<Bool>) -> Promise<Bool> {
        return doWhile {
            return race(cancellationPromise.then { _ in Promise<Bool>(value: false) }, body())
        }
    }
    
    
    public static func getCancellationPromise() -> (promise: Promise<Bool>, cancelFunction: () -> Void) {
        var abortFunction:  (() -> Void)? = nil
        let cancellationPromise: Promise<Bool> = Promise { resolve, reject in
            abortFunction = { resolve(false) }
        }
        
        return (promise: cancellationPromise, cancelFunction: abortFunction! )
    }
}
