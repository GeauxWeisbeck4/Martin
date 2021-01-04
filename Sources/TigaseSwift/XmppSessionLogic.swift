//
// XmppSessionLogic.swift
//
// TigaseSwift
// Copyright (C) 2016 "Tigase, Inc." <office@tigase.com>
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
import TigaseLogging
import Combine

extension StreamFeatures.StreamFeature {
    public static let startTLS = StreamFeatures.StreamFeature(name: "starttls", xmlns: "urn:ietf:params:xml:ns:xmpp-tls");
    public static let compressionZLIB = StreamFeatures.StreamFeature(.init(name: "compression", xmlns: "http://jabber.org/features/compress", value: nil), .init(name: "method", xmlns: nil, value: "zlib"));
}

/// Protocol which is used by other class to interact with classes responsible for session logic.
public protocol XmppSessionLogic: class {
    
    /// Keeps state of XMPP stream - this is not the same as state of `SocketConnection`
    var state:SocketConnector.State { get }
    var statePublisher: Published<SocketConnector.State>.Publisher { get }
    
    var connector: Connector { get }
    
    var streamLogger: StreamLogger? { get set }
    
    func start();
    func stop(force: Bool, completionHandler: (()->Void)?);
    
    /// Register to listen for events
    func bind();
    /// Unregister to stop listening for events
    func unbind();
        
    func send(stanza: Stanza, completionHandler: ((Result<Void,XMPPError>)->Void)?);
    
    /// Called to send data to keep connection open
    func keepalive();
    /// Using properties set decides which name use to connect to XMPP server
    func serverToConnectDetails() -> XMPPSrvRecord?;
}

extension XmppSessionLogic {
    
    public func send(stanza: Stanza) {
        send(stanza: stanza, completionHandler: nil);
    }
    
}

/** 
 Implementation of XmppSessionLogic protocol which is resposible for
 following XMPP session logic for socket connections.
 */
open class SocketSessionLogic: XmppSessionLogic {
    
    let logger = Logger(subsystem: "TigaseSwift", category: "SocketSessionLogic")
        
    private weak var context: Context?;
    private let modulesManager: XmppModulesManager;
    
    public var connector: Connector {
        return socketConnector;
    }
    private let socketConnector: SocketConnector;
    private let eventBus: EventBus;
    private let responseManager:ResponseManager;

    public var streamLogger: StreamLogger? {
        get {
            return socketConnector.streamLogger;
        }
        set {
            socketConnector.streamLogger = newValue;
        }
    }
    
    /// Keeps state of XMPP stream - this is not the same as state of `SocketConnection`
    @Published
    open private(set) var state:SocketConnector.State = .disconnected();
    public var statePublisher: Published<SocketConnector.State>.Publisher {
        return $state;
    }

    private let dispatcher: QueueDispatcher = QueueDispatcher(label: "SocketSessionLogic");
    private var seeOtherHost: XMPPSrvRecord? = nil;
    
    private let connectionConfiguration: ConnectionConfiguration;
    private var userJid: BareJID {
        return connectionConfiguration.userJid;
    }
    
    
    private var socketSubscriptions: Set<AnyCancellable> = [];
    private var moduleSubscriptions: Set<AnyCancellable> = [];
        
    public init(connector: SocketConnector, responseManager: ResponseManager, context: Context, seeOtherHost: XMPPSrvRecord?) {
        self.modulesManager = context.modulesManager;
        self.socketConnector = connector;
        self.eventBus = context.eventBus;
        self.connectionConfiguration = context.connectionConfiguration;
        self.context = context;
        self.responseManager = responseManager;
        self.seeOtherHost = seeOtherHost;
        
        connector.$state.dropFirst(1).receive(on: self.dispatcher.queue).sink(receiveValue: { [weak self] newState in
            guard newState != .connected else {
                return;
            }
            guard let that = self else {
                return;
            }
            switch newState {
            case .disconnected(let reason):
                if case .streamError(let errorElem) = reason {
                    guard that.onStreamError(errorElem) else {
                        return;
                    }
                }
            default:
                break;
            }
            that.state = newState;
        }).store(in: &socketSubscriptions);
        connector.streamEvents.receive(on: dispatcher.queue).sink(receiveValue: { [weak self] event in
            guard let that = self else {
                return;
            }
            switch event {
            case .streamOpen:
                that.startStream();
            case .streamClose:
                that.onStreamClose(completionHandler: nil);
            case .streamReceived(let stanza):
                that.receivedIncomingStanza(stanza);
            case .streamTerminate:
                that.onStreamTerminate();
            }
        }).store(in: &socketSubscriptions);
    }
    
    deinit {
        for subscription in socketSubscriptions {
            subscription.cancel();
        }
        for subscription in moduleSubscriptions {
            subscription.cancel();
        }
        self.dispatcher.sync {
            if state != .disconnected() {
                state = .disconnected();
            }
        }
    }
        
    open func bind() {
        context?.moduleOrNil(.auth)?.$state.receive(on: dispatcher.queue).sink(receiveValue: { [weak self] state in self?.authStateChanged(state) }).store(in: &moduleSubscriptions);
        context?.module(.streamFeatures).$streamFeatures.receive(on: self.dispatcher.queue).sink(receiveValue: { [weak self] streamFeatures in self?.processStreamFeatures(streamFeatures) }).store(in: &moduleSubscriptions);

        responseManager.start();
    }
    
    private func authStateChanged(_ state: AuthModule.AuthorizationStatus) {
        switch state {
        case .authorized:
            let streamFeaturesWithPipelining = modulesManager.moduleOrNil(.streamFeatures) as? StreamFeaturesModuleWithPipelining;

            if !(streamFeaturesWithPipelining?.active ?? false) {
                socketConnector.restartStream();
            }
        case .expectedAuthorization:
            guard let streamFeaturesWithPipelining = modulesManager.moduleOrNil(.streamFeatures) as? StreamFeaturesModuleWithPipelining else {
                return;
            }
            
            // current version of Tigase is not capable of pipelining auth with <stream> as get features is called before authentication is done!!
            if streamFeaturesWithPipelining.active {
                self.startStream();
            }
        default:
            logger.debug("Received auth state: \(state)")
        }
    }
    
    open func unbind() {
        for subscription in moduleSubscriptions {
            subscription.cancel();
        }
        moduleSubscriptions.removeAll();
        responseManager.stop();
    }
    
    open func start() {
        socketConnector.start(serverToConnect: self.serverToConnectDetails());
    }
    
    open func stop(force: Bool = false, completionHandler: (()->Void)? = nil) {
        if force {
            socketConnector.forceStop(completionHandler: completionHandler);
        } else {
            socketConnector.stop(completionHandler: completionHandler)
        }
    }
    
    open func serverToConnectDetails() -> XMPPSrvRecord? {
        if let redirect: XMPPSrvRecord = self.seeOtherHost {
            defer {
                self.seeOtherHost = nil;
            }
            return redirect;
        }
        return modulesManager.moduleOrNil(.streamManagement)?.resumptionLocation;
    }
    
    private func onStreamClose(completionHandler: (() -> Void)?) {
        if let streamManagementModule = modulesManager.moduleOrNil(.streamManagement) {
            streamManagementModule.request();
            streamManagementModule.sendAck();
        }
        if let completionHandler = completionHandler {
            dispatcher.async {
                completionHandler();
            }
        }
    }
        
    private func onStreamError(_ streamErrorEl: Element) -> Bool {
        if let seeOtherHostEl = streamErrorEl.findChild(name: "see-other-host", xmlns: "urn:ietf:params:xml:ns:xmpp-streams"), let seeOtherHost = SocketConnector.preprocessConnectionDetails(string: seeOtherHostEl.value), let lastConnectionDetails: XMPPSrvRecord = self.socketConnector.currentConnectionDetails {
            if let streamFeaturesWithPipelining = modulesManager.moduleOrNil(.streamFeatures) as? StreamFeaturesModuleWithPipelining {
                streamFeaturesWithPipelining.connectionRestarted();
            }
            
            self.logger.log("reconnecting via see-other-host to host \(seeOtherHost.0)");
            self.seeOtherHost = XMPPSrvRecord(port: seeOtherHost.1 ?? lastConnectionDetails.port, weight: 1, priority: 1, target: seeOtherHost.0, directTls: lastConnectionDetails.directTls);
            self.socketConnector.start(serverToConnect: self.serverToConnectDetails());
            return false;
        }
        let errorName = streamErrorEl.findChild(xmlns: "urn:ietf:params:xml:ns:xmpp-streams")?.name;
        let streamError = errorName == nil ? nil : StreamError(rawValue: errorName!);
        if let context = self.context {
            // how to change that into publisher?
            eventBus.fire(ErrorEvent.init(context: context, streamError: streamError));
        }
        return true;
    }
    
    private func onStreamTerminate() {
        // we may need to adjust those condition....
        if self.socketConnector.state == .connecting {
            modulesManager.moduleOrNil(.streamManagement)?.reset();
        }
    }
    
    private func receivedIncomingStanza(_ stanza:Stanza) {
//        dispatcher.async {
            do {
                for filter in self.modulesManager.filters {
                    if filter.processIncoming(stanza: stanza) {
                        return;
                    }
                }
            
                if let iq = stanza as? Iq, let handler = self.responseManager.getResponseHandler(for: iq) {
                    handler(iq);
                    return;
                }
            
                guard stanza.name != "iq" || (stanza.type != StanzaType.result && stanza.type != StanzaType.error) else {
                    return;
                }
            
                let modules = self.modulesManager.findModules(for: stanza);
//                self.log("stanza:", stanza, "will be processed by", modules);
                if !modules.isEmpty {
                    for module in modules {
                        try module.process(stanza: stanza);
                    }
                } else {
                    self.logger.debug("\(self.userJid) - feature-not-implemented \(stanza, privacy: .public)");
                    throw ErrorCondition.feature_not_implemented;
                }
            } catch let error as XMPPError {
                let errorStanza = error.createResponse(stanza);
                self.sendingOutgoingStanza(errorStanza);
            } catch let error as ErrorCondition {
                let errorStanza = error.createResponse(stanza);
                self.sendingOutgoingStanza(errorStanza);
            } catch {
                let errorStanza = ErrorCondition.undefined_condition.createResponse(stanza);
                self.sendingOutgoingStanza(errorStanza);
                self.logger.debug("\(self.userJid) - unknown unhandled exception \(error)")
            }
//        }
    }
    
    open func send(stanza: Stanza, completionHandler: ((Result<Void,XMPPError>)->Void)?) {
        dispatcher.async {
            let state = self.state;
            guard state == .connected || state == .connecting else {
                completionHandler?(.failure(.not_authorized("You are not connected to the XMPP server")));
                return;
            }
            
            for filter in self.modulesManager.filters {
                filter.processOutgoing(stanza: stanza);
            }
            self.socketConnector.send(.stanza(stanza));
            completionHandler?(.success(Void()));
        }
    }

    
    private func sendingOutgoingStanza(_ stanza: Stanza) {
        dispatcher.async {
            for filter in self.modulesManager.filters {
                filter.processOutgoing(stanza: stanza);
            }
            self.socketConnector.send(.stanza(stanza));
        }
    }
    
    open func keepalive() {
        if let pingModule = modulesManager.moduleOrNil(.ping) {
            pingModule.ping(JID(userJid), callback: { (stanza) in
                if stanza == nil {
                    self.logger.debug("\(self.userJid) - no response on ping packet - possible that connection is broken, reconnecting...");
                }
            });
        } else {
            socketConnector.keepAlive();
        }
    }
                
    private func processSessionBindedAndEstablished() {
        state = .connected;
        self.logger.debug("\(self.userJid) - session binded and established");
        if let discoveryModule = modulesManager.moduleOrNil(.disco) {
            discoveryModule.discoverServerFeatures(completionHandler: nil);
            discoveryModule.discoverAccountFeatures(completionHandler: nil);
        }
        
        if let streamManagementModule = modulesManager.moduleOrNil(.streamManagement) {
            if streamManagementModule.isAvailable {
                streamManagementModule.enable(completionHandler: nil);
            }
        }
    }
    
    private func processStreamFeatures(_ streamFeatures: StreamFeatures) {
        guard !streamFeatures.isNone else {
            return;
        }
        
        self.logger.debug("\(self.userJid) - processing stream features");
        let authorized = (modulesManager.moduleOrNil(.auth)?.state ?? .notAuthorized) == .authorized;
        
        if (!socketConnector.isTLSActive)
            && (!connectionConfiguration.disableTLS) && streamFeatures.contains(.startTLS) {
            socketConnector.startTLS();
        } else if ((!socketConnector.isCompressionActive) && (!connectionConfiguration.disableCompression) && streamFeatures.contains(.compressionZLIB)) {
            socketConnector.startZlib();
        } else if !authorized {
            if let authModule:AuthModule = modulesManager.moduleOrNil(.auth) {
                self.logger.debug("\(self.userJid) - starting authentication");
                if authModule.state != .inProgress {
                    authModule.login();
                } else {
                    self.logger.debug("\(self.userJid) - skipping authentication as it is already in progress!");
                    self.streamAuthenticated();
                }
            }
        } else if authorized {
            self.streamAuthenticated();
        }
        self.logger.debug("\(self.userJid) - finished processing stream features");
    }
    
    private func streamAuthenticated() {
        if let streamManagementModule = modulesManager.moduleOrNil(.streamManagement),  streamManagementModule.resumptionEnabled && streamManagementModule.isAvailable {
            streamManagementModule.resume(completionHandler: { [weak self] result in
                switch result {
                case .success(_):
                    self?.processSessionBindedAndEstablished();
                case .failure(_):
                    self?.context?.reset(scopes: [.session]);
                    self?.streamAuthenticatedNoStreamResumption();
                }
            });
        } else {
            streamAuthenticatedNoStreamResumption();
        }
    }
    
    private func streamAuthenticatedNoStreamResumption() {
        if let bindModule = self.modulesManager.moduleOrNil(.resourceBind) {
            bindModule.bind(completionHandler: { [weak self] result in
                switch result {
                case .failure(_):
                    self?.stop();
                case .success(_):
                    self?.resourceBound();
                }
            });
        } else {
            self.stop();
        }
    }
    
    private func resourceBound() {
        modulesManager.module(.sessionEstablishment).establish(completionHandler: { result in
            switch result {
            case .success(_):
                self.processSessionBindedAndEstablished();
            case .failure(_):
                //TODO: Should we handle failure somehow?
                break;
            }
        });
    }
    
    private func startStream() {
        // replace with this first one to enable see-other-host feature
        //self.send("<stream:stream from='\(userJid)' to='\(userJid.domain)' version='1.0' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>")
        let domain = userJid.domain
        let seeOtherHost = (self.connectionConfiguration.useSeeOtherHost && userJid.localPart != nil) ? " from='\(userJid)'" : ""
        self.socketConnector.send(.string("<stream:stream to='\(domain)'\(seeOtherHost) version='1.0' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>"));
        
        if let streamFeaturesWithPipelining = self.modulesManager.moduleOrNil(.streamFeatures) as? StreamFeaturesModuleWithPipelining {
            streamFeaturesWithPipelining.streamStarted();
        }
    }
    
    /// Event fired when XMPP stream error happens
    @available(*, deprecated, message: "Observe changes of state")
    open class ErrorEvent: AbstractEvent {
        
        /// Identifier of event which should be used during registration of `EventHandler`
        public static let TYPE = ErrorEvent();
        
        /// Type of stream error which was received - may be nil if it is not known
        public let streamError:StreamError?;
        
        init() {
            streamError = nil;
            super.init(type: "errorEvent");
        }
        
        public init(context: Context, streamError: StreamError?) {
            self.streamError = streamError;
            super.init(type: "errorEvent", context: context)
        }
    }
}
