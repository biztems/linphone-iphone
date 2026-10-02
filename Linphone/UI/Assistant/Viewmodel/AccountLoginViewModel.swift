/*
 * Copyright (c) 2010-2023 Belledonne Communications SARL.
 *
 * This file is part of Linphone
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import linphonesw
import SwiftUI

class AccountLoginViewModel: ObservableObject {
	
	private var coreContext = CoreContext.shared
	
	@Published var username: String = ""
	@Published var passwd: String = ""
	@Published var domain: String = AppServices.corePreferences.assistantDefaultDomain
	@Published var displayName: String = ""
	@Published var transportType: String = "TLS"
	@Published var authId: String = ""
	@Published var sipProxyUrl: String = AppServices.corePreferences.assistantDefaultProxy
	@Published var outboundProxy: String = AppServices.corePreferences.assistantDefaultProxy
	
	// BizVoIP: the manual sign-in form shows a spinner while an attempt runs and says why one failed. It used
	// to show nothing, and to empty the domain as soon as an attempt was sent, so after a failed one Login
	// stayed disabled: App Review's "tapping on Login did not produce any action" (1.0.1 (3)).
	@Published var isLoggingIn = false
	@Published var loginError: String?
	private var loginAttempt = 0
	
	private var mCoreDelegate: CoreDelegate!
	
	init() {}
	
	func login() {
		// BizVoIP: what was typed or pasted, without the spaces and line breaks that come with it; a username
		// written as 201@azienda.voip.biztems.it brings its domain.
		var username = self.username.trimmingCharacters(in: .whitespacesAndNewlines)
		var domain = self.domain.trimmingCharacters(in: .whitespacesAndNewlines)
		let passwd = self.passwd.trimmingCharacters(in: .whitespacesAndNewlines)
		let usernameWithDomain = username.split(separator: "@", maxSplits: 1)
		if usernameWithDomain.count == 2 {
			username = String(usernameWithDomain[0])
			domain = String(usernameWithDomain[1])
		}
		self.username = username
		self.domain = domain
		guard !username.isEmpty, !passwd.isEmpty, !domain.isEmpty else {
			loginError = String(localized: "assistant_login_error_missing_fields")
			return
		}
		let authId = self.authId.trimmingCharacters(in: .whitespacesAndNewlines)
		let sipProxyUrl = self.sipProxyUrl.trimmingCharacters(in: .whitespacesAndNewlines)
		let outboundProxy = self.outboundProxy.trimmingCharacters(in: .whitespacesAndNewlines)
		let transportType = self.transportType
		
		loginError = nil
		isLoggingIn = true
		if coreContext.accounts.isEmpty {  // a first account; "Add an account" opens the form over the main screens
			SharedMainViewModel.shared.manualSignInPending = true
		}
		loginAttempt += 1
		let attempt = loginAttempt
		// A registration that never ends (no answer at all) still gives the form back.
		DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
			guard self.loginAttempt == attempt, self.isLoggingIn else { return }
			self.isLoggingIn = false
			self.loginError = String(localized: "assistant_login_error_unreachable")
		}
		
		coreContext.doOnCoreQueue { core in
			guard self.coreContext.networkStatusIsConnected else {
				DispatchQueue.main.async {
					self.coreContext.loggingInProgress = false
					self.isLoggingIn = false
					self.loginError = String(localized: "assistant_login_error_unreachable")
					ToastViewModel.shared.show("Unavailable_network")
				}
				return
			}
			do {
				if domain != "sip.linphone.org" {
					if let assistantLinphone = Bundle.main.path(forResource: "assistant_third_party_default_values", ofType: nil) {
						core.loadConfigFromXml(xmlUri: assistantLinphone)
					}
				} else {
					if let assistantLinphone = Bundle.main.path(forResource: "assistant_linphone_default_values", ofType: nil) {
						core.loadConfigFromXml(xmlUri: assistantLinphone)
					}
				}
				
				// Get the transport protocol to use.
				// TLS is strongly recommended
				// Only use UDP if you don't have the choice
				var transport: TransportType
				if transportType == "TLS" {
					transport = TransportType.Tls
				} else if transportType == "TCP" {
					transport = TransportType.Tcp
				} else { transport = TransportType.Udp }
				
				// To configure a SIP account, we need an Account object and an AuthInfo object
				// The first one is how to connect to the proxy server, the second one stores the credentials
				
				// The auth info can be created from the Factory as it's only a data class
				// userID is set to null as it's the same as the username in our case
				// ha1 is set to null as we are using the clear text password. Upon first register, the hash will be computed automatically.
				// The realm will be determined automatically from the first register, as well as the algorithm
				let authInfo = try Factory.Instance.createAuthInfo(
					username: username,
					userid: authId,
					passwd: passwd,
					ha1: "",
					realm: "",
					domain: domain
				)
				
				// Account object replaces deprecated ProxyConfig object
				// Account object is configured through an AccountParams object that we can obtain from the Core
				
				let accountParams = try core.createAccountParams()
				
				// A SIP account is identified by an identity address that we can construct from the username and domain
				let identity = try Factory.Instance.createAddress(addr: String("sip:" + username + "@" + domain))
				try accountParams.setIdentityaddress(newValue: identity)
				
				// We also need to configure where the proxy server is located
				var serverAddress: Address
				if (!sipProxyUrl.isEmpty) {
					let server = sipProxyUrl.starts(with: "sip:") ? sipProxyUrl : String("sip:" + sipProxyUrl)
					serverAddress = try Factory.Instance.createAddress(addr: server)
				} else {
					serverAddress = try Factory.Instance.createAddress(addr: String("sip:" + domain))
				}
				
				// We use the Address object to easily set the transport protocol
				try serverAddress.setTransport(newValue: transport)
				try accountParams.setServeraddress(newValue: serverAddress)
				
				var routeAddress: Address
				if (!outboundProxy.isEmpty) {
					let server = outboundProxy.starts(with: "sip:") ? outboundProxy : String("sip:" + outboundProxy)
					routeAddress = try Factory.Instance.createAddress(addr: server)
					try routeAddress.setTransport(newValue: transport)
					try accountParams.setRoutesaddresses(newValue: [routeAddress])
				} else {
					try accountParams.setRoutesaddresses(newValue: [])
				}
				
				// And we ensure the account will start the registration process
				accountParams.registerEnabled = true
				
				if accountParams.pushNotificationAllowed {
					accountParams.pushNotificationAllowed = true
					accountParams.remotePushNotificationAllowed = true
				}
#if DEBUG
				let pushEnvironment = ".dev"
#else
				let pushEnvironment = ""
#endif
				accountParams.pushNotificationConfig?.provider = "apns" + pushEnvironment
				
				// Now that our AccountParams is configured, we can create the Account object
				let account = try core.createAccount(params: accountParams)
				
				// biztems: watch only this new account, and only until its first registration
				// succeeds or fails. The listener used to stay on the core for good and delete
				// any account whose registration failed later, e.g. while the server restarted.
				if let previousDelegate = self.mCoreDelegate {
					core.removeDelegate(delegate: previousDelegate)
				}
				var watcher: CoreDelegate?
				watcher = CoreDelegateStub(onAccountRegistrationStateChanged: { (core: Core, changedAccount: Account, state: RegistrationState, message: String) in
					guard changedAccount.getCobject == account.getCobject, state == .Ok || state == .Failed,
						  let delegate = watcher else { return }
					watcher = nil
					core.removeDelegate(delegate: delegate)
					
					Log.info("New registration state is \(state) for user id " +
							 "\( String(describing: changedAccount.params?.identityAddress?.asString())) = \(message), no longer watching it\n")
					
					if state == .Failed {  // If registration failed, remove account from core
						let reason = changedAccount.error
						if let authInfo = changedAccount.findAuthInfo() {
							core.removeAuthInfo(info: authInfo)
						}
						
						Log.warn("Registration failed for account \(changedAccount.displayName()) (\(reason)), deleting it from core")
						core.removeAccountWithData(account: changedAccount)
						
						// BizVoIP: the PBX answers 403 to a wrong password, 404 to an unknown extension or domain.
						let wrongDetails = reason == .Forbidden || reason == .Unauthorized || reason == .NotFound
						DispatchQueue.main.async {
							self.isLoggingIn = false
							if wrongDetails {
								self.loginError = String(localized: "assistant_login_error_credentials")
							} else {
								self.loginError = String(localized: "assistant_login_error_unreachable")
							}
						}
					} else {
						// BizVoIP: the form starts afresh for the next account only once this one is in.
						DispatchQueue.main.async {
							self.isLoggingIn = false
							SharedMainViewModel.shared.manualSignInPending = false
							self.domain = AppServices.corePreferences.assistantDefaultDomain
							self.transportType = "TLS"
							self.authId = ""
							self.outboundProxy = AppServices.corePreferences.assistantDefaultProxy
						}
					}
				})
				self.mCoreDelegate = watcher
				if let watcher = watcher {
					core.addDelegate(delegate: watcher)
				}
				
				// Now let's add our objects to the Core
				core.addAuthInfo(info: authInfo)
				try core.addAccount(account: account)
				
				// Also set the newly added account as default
				core.defaultAccount = account
				
			} catch {
				// BizVoIP: e.g. an address that does not parse; this used to end the attempt without a word.
				Log.error("[AccountLoginViewModel] login failed: \(error.localizedDescription)")
				DispatchQueue.main.async {
					self.isLoggingIn = false
					self.loginError = String(localized: "assistant_login_error_credentials")
				}
			}
		}
	}
	
	func unregister() {
		coreContext.doOnCoreQueue { core in
			// Here we will disable the registration of our Account
			if let account = core.defaultAccount {
				
				let params = account.params
				// Returned params object is const, so to make changes we first need to clone it
				let clonedParams = params?.clone()
				
				// Now let's make our changes
				clonedParams?.registerEnabled = false
				
				// And apply them
				account.params = clonedParams
			}
		}
	}
	
	func delete() {
		coreContext.doOnCoreQueue { core in
			// To completely remove an Account
			if let account = core.defaultAccount {
				core.removeAccountWithData(account: account)
				
				// To remove all accounts use
				core.clearAccounts()
				
				// Same for auth info
				core.clearAllAuthInfo()
			}
		}
	}
}
