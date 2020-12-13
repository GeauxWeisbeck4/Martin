//
// CurrentValueSubject.swift
//
// TigaseSwift
// Copyright (C) 2020 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License,
// or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see http://www.gnu.org/licenses/.
//

import Foundation

public class CurrentValueSubject<Output, Failure: Error>: AbstractPublisher<Output,Failure>, Subject {
    
    public typealias Output = Output
    public typealias Failure = Failure

    private let lock = UnfairLock();

    private var _value: Output;
    public var value: Output {
        get {
            lock.lock();
            defer {
                lock.unlock();
            }
            return _value;
        }
        set {
            send(newValue);
        }
    }
    
    public init(_ value: Output) {
        self._value = value;
    }

    public func send(_ value: Output) {
        self.offer(value)
        lock.lock();
        self._value = value;
        lock.unlock();
    }
}
